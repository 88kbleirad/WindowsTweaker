# WindowsTweaker - external tool integration (Microsoft Activation Scripts).
#
# MAS is a third-party activator. WindowsTweaker does not embed, port or modify it: this
# file downloads the upstream file from its official repository at one pinned commit,
# verifies it, and runs one Windows activation method of it as a separate process when the
# user asks for exactly that. Nothing here runs during navigation, refresh, startup or
# diagnostics.
#
# Why an external process and not imported code:
#   * MAS is GPL-3.0. Copying its source into this repository would make the combined work
#     subject to the GPL; downloading it at the user's explicit request does not.
#   * The upstream script is the authority on its own behaviour. Which workflow runs is
#     decided here only in the sense that one documented command-line switch of the method
#     the user selected in the interface is passed; no menu is navigated, no keystroke is
#     fed to it (SendKeys is never used) and no upstream code is patched.
#
# The switch table (Get-WtWindowsActivationMethods) is closed and evidence-pinned: every entry
# names the upstream line that implements it and the documentation that describes it. Office,
# ESU, KMS-host, edition-change and reset switches are not represented at all, so no
# combination of settings can reach them.
#
# Provenance chain, strongest first:
#   1. HTTPS to a hard-coded host allow-list; every redirect hop is re-validated.
#   2. The URL names an immutable commit, never a branch or "latest".
#   3. The downloaded bytes must match the size and the git blob id (SHA-1) that the
#      upstream repository reports for that commit. Git's blob id is upstream content
#      identity, so a changed entry point at the pinned commit is refused.
#   4. The bytes must also match the SHA-256 recorded in this file when the pin was made.
#      That hash was computed by this project, not published upstream: it detects a
#      changed or corrupted artifact, and it is NOT a claim of independent authenticity.
#   5. The bytes are staged, verified, and only then published; the provenance record that
#      marks the copy "ready" is written last, atomically.
#
# Privacy and safety: the child process runs in its own console with its own standard
# streams. Its output is never read, captured or logged, so no product key or activation
# response can reach the log. Nothing here reboots, retries, deletes licensing stores,
# changes Defender configuration or elevates silently.

$Script:WtExternalToolId = 'microsoft-activation-scripts'
$Script:WtExternalToolProvenanceSchema = 'windows-tweaker.external-tool/1'
$Script:WtExternalToolUserAgent = 'WindowsTweaker-external-tool/1.0'
$Script:WtExternalToolLaunching = $false

# Hosts a pinned or resolved download may use. raw.githubusercontent.com serves the pinned
# file; the api host resolves a newer upstream release only when the user explicitly asks
# for that; the remaining hosts are GitHub's own asset/CDN hosts.
$Script:WtExternalToolAllowedHosts = @(
    'raw.githubusercontent.com'
    'api.github.com'
    'github.com'
    'codeload.github.com'
    'objects.githubusercontent.com'
    'github-releases.githubusercontent.com'
    'release-assets.githubusercontent.com'
)

<#
.SYNOPSIS
    Returns the pinned upstream definition shipped with this revision.
.DESCRIPTION
    Every value here was read from the upstream repository at the commit named in
    Commit, except Sha256: that digest was computed by this project from those bytes when
    the pin was made (see the provenance chain at the top of this file).

    Upstream: https://github.com/massgravel/Microsoft-Activation-Scripts
      * release tag 3.12 ("v3.12 8 Years of MAS", published 2026-07-04)
      * commit      40c74d0d7f42146b1dd1ab59b5c7e836d6a56d1f
      * file        MAS/All-In-One-Version-KL/MAS_AIO.cmd (761964 bytes)
      * git blob    33513d90d2c8332d10c713a63e5468be4a78cc23
      * license     GNU GPL v3 (LICENSE in that repository)
.OUTPUTS
    An ordered dictionary describing the pin.
#>
function Get-WtExternalToolSpec
{
    [CmdletBinding()]
    param ()

    $Commit = '40c74d0d7f42146b1dd1ab59b5c7e836d6a56d1f'
    $RepositoryPath = 'MAS/All-In-One-Version-KL/MAS_AIO.cmd'

    return [ordered]@{
        Id              = 'microsoft-activation-scripts'
        Name            = 'Microsoft Activation Scripts (MAS)'
        Repository      = 'massgravel/Microsoft-Activation-Scripts'
        RepositoryUrl   = 'https://github.com/massgravel/Microsoft-Activation-Scripts'
        DocumentationUrl = 'https://massgrave.dev/'
        License         = 'GPL-3.0'
        LicenseUrl      = 'https://github.com/massgravel/Microsoft-Activation-Scripts/blob/{0}/LICENSE' -f $Commit
        Tag             = '3.12'
        Commit          = $Commit
        RepositoryPath  = $RepositoryPath
        FileName        = 'MAS_AIO.cmd'
        Bytes           = 761964
        Sha256          = '850f979665fb93999acae93f4790c1ff8ed2041532060b7966a121c2d29a0bfa'
        GitBlobSha1     = '33513d90d2c8332d10c713a63e5468be4a78cc23'
        DownloadUrl     = 'https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/{0}/{1}' -f $Commit, $RepositoryPath
        MaxBytes        = 4194304
        TimeoutSeconds  = 60
        MaxRedirects    = 5
        PinSource       = 'shipped'
        RequiresAdmin   = $true
    }
}

<#
.SYNOPSIS
    Returns the hosts a download or an upstream lookup may use.
#>
function Get-WtExternalToolAllowedHosts
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    return @($Script:WtExternalToolAllowedHosts)
}

<#
.SYNOPSIS
    Returns the only host the documentation link may point at.
.DESCRIPTION
    Kept apart from the download allow-list on purpose: the upstream documentation is not
    served by GitHub, and widening the list a download may use, only to make a link work,
    would weaken the download policy for no reason.
#>
function Get-WtExternalToolDocumentationHosts
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    return @('massgrave.dev')
}

<#
.SYNOPSIS
    Validates the documentation URL of the pin: absolute, HTTPS, documentation host.
#>
function Assert-WtExternalToolDocumentationUrl
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Url)

    $Uri = $null
    if (-not [uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$Uri))
    {
        throw "NETWORK: Refusing malformed documentation URL: $Url"
    }
    if ($Uri.Scheme -ne 'https')
    {
        throw "NETWORK: Refusing non-HTTPS documentation URL: $Url"
    }
    if ((Get-WtExternalToolDocumentationHosts) -notcontains $Uri.Host)
    {
        throw "NETWORK: Documentation host not allowed: $($Uri.Host)"
    }
    return $Uri
}

#region Local layout

<#
.SYNOPSIS
    Application-owned directory that holds the downloaded upstream file.
.DESCRIPTION
    Inside the WindowsTweaker data root, so a remove action can only ever delete files this
    feature created, and a portable install (WT_DATA_ROOT) keeps them with the rest of its
    state.
#>
function Get-WtExternalToolRoot
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    return (Join-Path (Join-Path (Get-WtDataRoot) 'external-tools') $Script:WtExternalToolId)
}

<#
.SYNOPSIS
    Path of the entry point file downloaded from upstream.
#>
function Get-WtExternalToolEntryPointPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][object]$Spec)

    if (-not $Spec) { $Spec = Get-WtExternalToolSpec }

    return [System.IO.Path]::Combine((Get-WtExternalToolRoot), [string]$Spec.FileName)
}

<#
.SYNOPSIS
    Path of the provenance record written when a download is published.
#>
function Get-WtExternalToolProvenancePath
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    return [System.IO.Path]::Combine((Get-WtExternalToolRoot), 'provenance.json')
}

<#
.SYNOPSIS
    Directory a download is written to before it is verified and published.
#>
function Get-WtExternalToolStagingRoot
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    return [System.IO.Path]::Combine((Get-WtExternalToolRoot), '.staging')
}

<#
.SYNOPSIS
    Reports whether this platform can run the upstream tool at all.
.DESCRIPTION
    MAS is a Windows batch script that drives Windows licensing interfaces. On any other
    platform the workspace reports the capability instead of pretending to offer it.
#>
function Test-WtExternalToolSupported
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    return [bool](Test-WtIsWindows)
}

#endregion Local layout

#region Transport

<#
.SYNOPSIS
    Validates a URL: absolute, HTTPS, allowed host.
.DESCRIPTION
    The host allow-list is part of the pin: without it, a redirect (or a mis-edited value)
    could point the download at an arbitrary server. Returns the parsed [uri].
#>
function Assert-WtExternalToolUrl
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Url)

    $Uri = $null
    if (-not [uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$Uri))
    {
        throw "NETWORK: Refusing malformed URL: $Url"
    }
    if ($Uri.Scheme -ne 'https')
    {
        throw "NETWORK: Refusing non-HTTPS URL: $Url"
    }
    if ((Get-WtExternalToolAllowedHosts) -notcontains $Uri.Host)
    {
        throw "NETWORK: Host not allowed: $($Uri.Host)"
    }
    return $Uri
}

<#
.SYNOPSIS
    Resolves and validates one redirect hop.
.DESCRIPTION
    A relative Location is resolved against the current URL; the result must again be
    HTTPS on an allowed host. Called once per hop, so every hop of a redirect chain is
    validated rather than only the first URL.
#>
function Resolve-WtExternalToolRedirect
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][uri]$Base,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Location,
        [Parameter(Mandatory = $true)][string]$SourceUrl
    )

    if (-not $Location)
    {
        throw "NETWORK: Redirect without a Location header from $SourceUrl."
    }

    $Target = $Location
    if ($Location -notmatch '^[A-Za-z][A-Za-z0-9+.\-]*://')
    {
        $Target = ([uri]::new($Base, $Location)).AbsoluteUri
    }

    $null = Assert-WtExternalToolUrl -Url $Target
    return $Target
}

<#
.SYNOPSIS
    Copies a response body into a target stream, bounded in size and in time.
.DESCRIPTION
    The bound is enforced while reading, not from Content-Length alone: a response that
    lies about its length (or omits it) still cannot exceed MaxBytes, and a server that
    stalls cannot hold the interface forever. The target is flushed when the copy ends, and
    a file target is also flushed to the device.

    Every failure names its class: INTEGRITY when the size or the time bound is hit,
    CANCELLED when the caller asked to stop, NETWORK when the stream cannot be read.
    SourceLabel only names the source in those messages (the parameter is not called Source
    because Source is the stream).

    Progress and cancellation are optional and shared by reference: Progress receives
    Received (and its Total when the caller already knew it) and Cancel.Requested is checked
    once per chunk, which is the granularity at which a download can be stopped. Both are
    [hashtable]::Synchronized tables owned by the caller - typically a background task - so
    this reader never has to call back into the interface.
.PARAMETER Progress
    Shared progress table: Received, Total, and a Phase the caller sets.
.PARAMETER Cancel
    Shared cancellation table with a Requested flag.
.OUTPUTS
    [long] the number of bytes copied.
#>
function Copy-WtExternalToolResponseStream
{
    [CmdletBinding()]
    [OutputType([long])]
    param
    (
        [Parameter(Mandatory = $true)][System.IO.Stream]$Source,
        [Parameter(Mandatory = $true)][System.IO.Stream]$Target,
        [Parameter(Mandatory = $false)][int]$MaxBytes = 0,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 60,
        [Parameter(Mandatory = $false)][string]$SourceLabel = 'the server',
        [Parameter(Mandatory = $false)][AllowNull()][object]$Progress = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Cancel = $null
    )

    $Buffer = [byte[]]::new(65536)
    $Received = [long]0
    $Deadline = if ($TimeoutSeconds -gt 0) { [datetime]::UtcNow.AddSeconds($TimeoutSeconds) } else { $null }

    try
    {
        while (($Read = $Source.Read($Buffer, 0, $Buffer.Length)) -gt 0)
        {
            if ($Cancel -and $Cancel.Requested)
            {
                throw "CANCELLED: The download from $SourceLabel was cancelled after $Received bytes."
            }

            if ($Deadline -and [datetime]::UtcNow -gt $Deadline)
            {
                throw "INTEGRITY: Reading from $SourceLabel exceeded the $TimeoutSeconds second limit."
            }

            $Received += $Read
            if ($MaxBytes -gt 0 -and $Received -gt $MaxBytes)
            {
                throw "INTEGRITY: The response from $SourceLabel exceeds the $MaxBytes byte limit."
            }

            $Target.Write($Buffer, 0, $Read)

            if ($Progress)
            {
                $Progress.Received = $Received
                if ($Progress.Total -gt 0)
                {
                    $Progress.Percent = [int][math]::Min(100, [math]::Floor(($Received * 100) / [double]$Progress.Total))
                }
            }
        }
    }
    catch
    {
        $Message = $_.Exception.Message
        if ($Message -match '^(NETWORK|INTEGRITY|RUNTIME|LAUNCH|POLICY|CANCELLED):') { throw }
        throw "NETWORK: Reading from $SourceLabel failed: $($_.Exception.GetBaseException().Message)"
    }

    if ($Target -is [System.IO.FileStream])
    {
        $Target.Flush($true)
    }
    else
    {
        $Target.Flush()
    }

    return $Received
}

<#
.SYNOPSIS
    Fetches one HTTPS resource into a caller-supplied stream.
.DESCRIPTION
    Redirects are followed manually so each hop passes Assert-WtExternalToolUrl; the chain
    is bounded, the body is bounded, and the whole request carries a timeout. TLS 1.2 is
    requested for this request only, because Windows PowerShell 5.1 on an older build may
    otherwise negotiate TLS 1.0; the process-wide setting is restored before returning.

    Windows PowerShell 5.1 runs on .NET Framework, where HttpContent exposes only the
    asynchronous accessors (ReadAsStreamAsync arrived with .NET 5), and where System.Net.Http
    is not loaded by default - hence Add-Type below and the awaited accessor in the callers.

    With -HeadersOnly the response is validated (status, redirect chain, length bound) and
    discarded without reading the body: that is how the pinned URL is checked live without
    downloading the artifact.
.PARAMETER Target
    Writable stream that receives the body. Ignored with -HeadersOnly.
.OUTPUTS
    An ordered dictionary: Status, Bytes, FinalUri, Redirects, ContentLength.
#>
function Get-WtExternalToolContent
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $false)][System.IO.Stream]$Target,
        [Parameter(Mandatory = $false)][int]$MaxBytes = 0,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 60,
        [Parameter(Mandatory = $false)][int]$MaxRedirects = 5,
        [Parameter(Mandatory = $false)][switch]$HeadersOnly,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Progress = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Cancel = $null
    )

    $null = Assert-WtExternalToolUrl -Url $Url

    # Loads System.Net.Http on Windows PowerShell 5.1 (it is part of .NET Framework 4.5).
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { $null = $_ }

    $Result = [ordered]@{
        Status        = 'failed'
        Bytes         = [long]0
        FinalUri      = $Url
        Redirects     = 0
        ContentLength = [long]-1
    }

    $SavedProtocol = [System.Net.ServicePointManager]::SecurityProtocol
    try
    {
        try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }

        $Client = $null
        try
        {
            $Handler = [System.Net.Http.HttpClientHandler]::new()
            $Handler.AllowAutoRedirect = $false
            $Handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None
            $Client = [System.Net.Http.HttpClient]::new($Handler)
            $Client.Timeout = [timespan]::FromSeconds([math]::Max(1, $TimeoutSeconds))
            $null = $Client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $Script:WtExternalToolUserAgent)

            $Current = $Url
            while ($true)
            {
                $Uri = Assert-WtExternalToolUrl -Url $Current
                $Request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
                $Response = $null
                try
                {
                    $Response = $Client.SendAsync($Request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                }
                catch
                {
                    $Request.Dispose()
                    throw "NETWORK: Request to $($Uri.AbsoluteUri) failed: $($_.Exception.GetBaseException().Message)"
                }

                $Status = [int]$Response.StatusCode
                if ($Status -in 301, 302, 303, 307, 308)
                {
                    $Location = ''
                    if ($Response.Headers.Location) { $Location = $Response.Headers.Location.OriginalString }
                    $Response.Dispose()
                    $Request.Dispose()

                    if ($Result.Redirects -ge [math]::Max(0, $MaxRedirects))
                    {
                        throw "NETWORK: Too many redirects (limit $MaxRedirects) for $Url."
                    }

                    $Current = Resolve-WtExternalToolRedirect -Base $Uri -Location $Location -SourceUrl $Current
                    $Result.Redirects = [int]$Result.Redirects + 1
                    continue
                }

                try
                {
                    if ($Status -ne 200)
                    {
                        throw "NETWORK: HTTP $Status for $($Uri.AbsoluteUri)."
                    }

                    $Length = [long]-1
                    if ($null -ne $Response.Content.Headers.ContentLength)
                    {
                        $Length = [long]$Response.Content.Headers.ContentLength
                    }
                    $Result.ContentLength = $Length
                    if ($Progress -and $Length -gt 0)
                    {
                        $Progress.Total = $Length
                    }

                    if ($MaxBytes -gt 0 -and $Length -gt $MaxBytes)
                    {
                        throw "INTEGRITY: $($Uri.AbsoluteUri) reports $Length bytes, above the $MaxBytes byte limit."
                    }

                    $Result.FinalUri = $Uri.AbsoluteUri

                    if ($HeadersOnly)
                    {
                        $Result.Status = 'succeeded'
                        return $Result
                    }

                    $Stream = $null
                    try
                    {
                        if ($Progress) { $Progress.Phase = 'downloading' }

                        # .NET Framework has ReadAsStreamAsync() only; the awaited form exists there.
                        $Stream = $Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                        $Result.Bytes = Copy-WtExternalToolResponseStream -Source $Stream -Target $Target -MaxBytes $MaxBytes `
                            -TimeoutSeconds $TimeoutSeconds -SourceLabel $Uri.AbsoluteUri -Progress $Progress -Cancel $Cancel
                    }
                    catch
                    {
                        $Message = $_.Exception.Message
                        if ($Message -match '^(NETWORK|INTEGRITY|RUNTIME|LAUNCH|POLICY|CANCELLED):') { throw }
                        throw "NETWORK: Reading $($Uri.AbsoluteUri) failed: $($_.Exception.GetBaseException().Message)"
                    }
                    finally
                    {
                        if ($Stream) { $Stream.Dispose() }
                    }

                    $Result.Status = 'succeeded'
                    return $Result
                }
                finally
                {
                    $Response.Dispose()
                    $Request.Dispose()
                }
            }
        }
        catch
        {
            $Failure = $_.Exception.Message
            if ($Failure -match '^(NETWORK|INTEGRITY|RUNTIME|LAUNCH|POLICY|CANCELLED):') { throw }
            throw "NETWORK: Download of $Url failed: $($_.Exception.GetBaseException().Message)"
        }
        finally
        {
            if ($Client) { $Client.Dispose() }
        }
    }
    finally
    {
        try { [System.Net.ServicePointManager]::SecurityProtocol = $SavedProtocol } catch { $null = $_ }
    }
}

<#
.SYNOPSIS
    Downloads one HTTPS resource to a file.
.OUTPUTS
    An ordered dictionary: Status, Bytes, FinalUri, Redirects, ContentLength.
#>
function Save-WtExternalToolDownload
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][int]$MaxBytes = 0,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 60,
        [Parameter(Mandatory = $false)][int]$MaxRedirects = 5,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Progress = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Cancel = $null
    )

    $Directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
    if ($Directory) { New-WtDirectory -Path $Directory }

    $Target = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try
    {
        return (Get-WtExternalToolContent -Url $Url -Target $Target -MaxBytes $MaxBytes -TimeoutSeconds $TimeoutSeconds -MaxRedirects $MaxRedirects `
            -Progress $Progress -Cancel $Cancel)
    }
    finally
    {
        $Target.Dispose()
    }
}

<#
.SYNOPSIS
    Reads a small JSON document from an allowed HTTPS host.
.DESCRIPTION
    Used for the upstream release metadata an explicit update needs. The body is bounded
    the same way a download is; a document that does not parse is a failure, never a
    silently empty answer.
#>
function Get-WtExternalToolJson
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $false)][int]$MaxBytes = 262144,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 30,
        [Parameter(Mandatory = $false)][int]$MaxRedirects = 5,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Progress = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Cancel = $null
    )

    $Memory = [System.IO.MemoryStream]::new()
    try
    {
        $null = Get-WtExternalToolContent -Url $Url -Target $Memory -MaxBytes $MaxBytes -TimeoutSeconds $TimeoutSeconds -MaxRedirects $MaxRedirects `
            -Progress $Progress -Cancel $Cancel
        $Text = [System.Text.Encoding]::UTF8.GetString($Memory.ToArray())
    }
    finally
    {
        $Memory.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($Text))
    {
        throw "INTEGRITY: $Url returned an empty document."
    }

    try
    {
        return (ConvertFrom-WtJson -Text $Text -AsHashtable)
    }
    catch
    {
        throw "INTEGRITY: $Url did not return a JSON document: $($_.Exception.Message)"
    }
}

#endregion Transport

#region Integrity

<#
.SYNOPSIS
    Returns the hex digest of a file for one algorithm.
.DESCRIPTION
    The file is streamed, never loaded whole. An SHA-1 digest returns '' when the runtime
    refuses SHA-1 (a FIPS-only policy blocks it): the caller then reports the blob check as
    unavailable instead of failing the download for a policy it cannot control.
.OUTPUTS
    [string] the digest, or '' when it cannot be computed.
#>
function Get-WtExternalToolHash
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][ValidateSet('SHA1', 'SHA256')][string]$Algorithm = 'SHA256'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        return ''
    }

    $Hasher = $null
    try
    {
        $Hasher = if ($Algorithm -eq 'SHA1')
        {
            [System.Security.Cryptography.SHA1]::Create()
        }
        else
        {
            [System.Security.Cryptography.SHA256]::Create()
        }
    }
    catch
    {
        return ''
    }

    $Stream = $null
    try
    {
        $Stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $Bytes = $Hasher.ComputeHash($Stream)
    }
    catch
    {
        return ''
    }
    finally
    {
        if ($Stream) { $Stream.Dispose() }
        if ($Hasher) { $Hasher.Dispose() }
    }

    $Builder = [System.Text.StringBuilder]::new($Bytes.Length * 2)
    foreach ($Byte in $Bytes) { [void]$Builder.Append($Byte.ToString('x2')) }
    return $Builder.ToString()
}

<#
.SYNOPSIS
    Returns git's own content id for a file ("blob <size>\0<content>", SHA-1).
.DESCRIPTION
    GitHub reports this id per path at a commit, so comparing it proves the bytes are the
    ones that commit contains - the closest thing to an upstream checksum this artifact
    has (upstream publishes no signed checksum file for it).
.OUTPUTS
    [string] the blob id, or '' when it cannot be computed.
#>
function Get-WtExternalToolGitBlobHash
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        return ''
    }

    $Hasher = $null
    try { $Hasher = [System.Security.Cryptography.SHA1]::Create() } catch { return '' }

    $Stream = $null
    try
    {
        $Stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $Length = $Stream.Length
        $Header = [System.Text.Encoding]::ASCII.GetBytes("blob $Length`0")
        $null = $Hasher.TransformBlock($Header, 0, $Header.Length, $null, 0)

        $Buffer = [byte[]]::new(65536)
        while (($Read = $Stream.Read($Buffer, 0, $Buffer.Length)) -gt 0)
        {
            $null = $Hasher.TransformBlock($Buffer, 0, $Read, $null, 0)
        }
        $null = $Hasher.TransformFinalBlock([byte[]]@(), 0, 0)
        $Bytes = $Hasher.Hash
    }
    catch
    {
        return ''
    }
    finally
    {
        if ($Stream) { $Stream.Dispose() }
        if ($Hasher) { $Hasher.Dispose() }
    }

    $Builder = [System.Text.StringBuilder]::new($Bytes.Length * 2)
    foreach ($Byte in $Bytes) { [void]$Builder.Append($Byte.ToString('x2')) }
    return $Builder.ToString()
}

<#
.SYNOPSIS
    Publishes a verified staging file at its final path in one step.
.DESCRIPTION
    The destination is either created (first download) or replaced, so a reader never sees a
    half-written file and a failed publish leaves the previous copy untouched.
#>
function Publish-WtExternalToolFile
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][string]$StagingPath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-WtAtomicReplaceSupported))
    {
        throw 'RUNTIME: This PowerShell runtime cannot replace a file atomically (System.IO.File.Replace is unavailable), so the verified download was not published.'
    }

    $Full = [System.IO.Path]::GetFullPath($Path)
    $Directory = [System.IO.Path]::GetDirectoryName($Full)
    if ($Directory) { New-WtDirectory -Path $Directory }

    if ([System.IO.File]::Exists($Full))
    {
        # A typed null: a plain $null binds to the empty string and .NET rejects that path.
        [System.IO.File]::Replace([System.IO.Path]::GetFullPath($StagingPath), $Full, [System.Management.Automation.Language.NullString]::Value, $true)
    }
    else
    {
        [System.IO.File]::Move([System.IO.Path]::GetFullPath($StagingPath), $Full)
    }

    return $Full
}

#endregion Integrity

#region Provenance and state

<#
.SYNOPSIS
    Reads one field of a parsed JSON document, whether it is a dictionary or an object.
.DESCRIPTION
    ConvertFrom-WtJson returns hashtables on PowerShell 7 and ordered dictionaries on
    Windows PowerShell 5.1; indexing into the document directly would therefore work on
    one runtime and silently return $null on the other. Every field read goes through here.
#>
function Get-WtExternalToolJsonProperty
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][AllowNull()][object]$Document,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Document) { return $null }

    if ($Document -is [System.Collections.IDictionary])
    {
        if ($Document.Contains($Name)) { return $Document[$Name] }
        return $null
    }

    $Property = $Document.PSObject.Properties[$Name]
    if ($Property) { return $Property.Value }
    return $null
}

<#
.SYNOPSIS
    Reads the provenance record of the local copy.
.DESCRIPTION
    Returns $null when there is no record, and a dictionary with a Problem member when the
    record exists but cannot be trusted (unreadable, wrong schema, missing a pinned value).
    A record is never "repaired" here: only a new download writes one.
#>
function Read-WtExternalToolProvenance
{
    [CmdletBinding()]
    param ()

    $Path = Get-WtExternalToolProvenancePath
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        return $null
    }

    try
    {
        $Text = Read-WtTextFile -Path $Path
        $Record = ConvertFrom-WtJson -Text $Text -AsHashtable
    }
    catch
    {
        return @{ Problem = "The provenance record could not be read: $($_.Exception.Message)" }
    }

    if (-not $Record -or $Record -isnot [System.Collections.IDictionary])
    {
        return @{ Problem = 'The provenance record is not an object.' }
    }

    if ([string](Get-WtExternalToolJsonProperty -Document $Record -Name 'schema') -ne $Script:WtExternalToolProvenanceSchema)
    {
        return @{ Problem = 'The provenance record was written by a different revision (schema mismatch).' }
    }

    foreach ($Field in 'toolId', 'repository', 'tag', 'commit', 'sha256', 'bytes', 'fileName', 'downloadUrl')
    {
        if ([string]::IsNullOrWhiteSpace([string](Get-WtExternalToolJsonProperty -Document $Record -Name $Field)))
        {
            return @{ Problem = "The provenance record is incomplete (missing '$Field')." }
        }
    }

    return $Record
}

<#
.SYNOPSIS
    Returns the pin that the local copy is verified against.
.DESCRIPTION
    A provenance record wins over the shipped pin, because it describes the copy that is
    actually on disk (a user may have updated it explicitly). Without a usable record the
    shipped pin applies.
#>
function Get-WtExternalToolPin
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][object]$Spec,
        [Parameter(Mandatory = $false)][object]$Provenance
    )

    if (-not $Spec) { $Spec = Get-WtExternalToolSpec }

    if ($Provenance -and $Provenance -is [System.Collections.IDictionary] -and -not $Provenance.Contains('Problem'))
    {
        return [ordered]@{
            Tag         = [string](Get-WtExternalToolJsonProperty -Document $Provenance -Name 'tag')
            Commit      = [string](Get-WtExternalToolJsonProperty -Document $Provenance -Name 'commit')
            Bytes       = [long](Get-WtExternalToolJsonProperty -Document $Provenance -Name 'bytes')
            Sha256      = [string](Get-WtExternalToolJsonProperty -Document $Provenance -Name 'sha256')
            GitBlobSha1 = [string](Get-WtExternalToolJsonProperty -Document $Provenance -Name 'gitBlobSha1')
            DownloadUrl = [string](Get-WtExternalToolJsonProperty -Document $Provenance -Name 'downloadUrl')
            FileName    = [string](Get-WtExternalToolJsonProperty -Document $Provenance -Name 'fileName')
            PinSource   = [string](Get-WtExternalToolJsonProperty -Document $Provenance -Name 'pinSource')
        }
    }

    return [ordered]@{
        Tag         = [string]$Spec.Tag
        Commit      = [string]$Spec.Commit
        Bytes       = [long]$Spec.Bytes
        Sha256      = [string]$Spec.Sha256
        GitBlobSha1 = [string]$Spec.GitBlobSha1
        DownloadUrl = [string]$Spec.DownloadUrl
        FileName    = [string]$Spec.FileName
        PinSource   = [string]$Spec.PinSource
    }
}

<#
.SYNOPSIS
    Reads the local copy's status (filesystem only, no network).
.DESCRIPTION
    Status is one of (Supported reports the platform separately):
      Missing     - nothing has been downloaded;
      Ready       - the file is present and matches its pin;
      Mismatch    - the file is present and does not match its pin (size or digest).
    Nothing is downloaded, repaired or deleted here: this is what the workspace shows
    before the user chooses an action.
.OUTPUTS
    An ordered dictionary with Status, Ready, Path, Bytes, Sha256, GitBlobSha1, Pin,
    Provenance, ProvenanceProblem, ProvenanceSource, Reason.
#>
function Get-WtExternalToolState
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][object]$Spec)

    if (-not $Spec) { $Spec = Get-WtExternalToolSpec }

    $Path = Get-WtExternalToolEntryPointPath -Spec $Spec
    $Provenance = Read-WtExternalToolProvenance
    $Problem = ''
    if ($Provenance -and $Provenance -is [System.Collections.IDictionary] -and $Provenance.Contains('Problem'))
    {
        $Problem = [string]$Provenance['Problem']
        $Provenance = $null
    }

    $Pin = Get-WtExternalToolPin -Spec $Spec -Provenance $Provenance

    $State = [ordered]@{
        Id                = [string]$Spec.Id
        Name              = [string]$Spec.Name
        Supported         = [bool](Test-WtExternalToolSupported)
        Path              = $Path
        Root              = (Get-WtExternalToolRoot)
        Installed         = [bool](Test-Path -LiteralPath $Path -PathType Leaf)
        Ready             = $false
        Status            = 'Missing'
        Bytes             = [long]0
        Sha256            = ''
        GitBlobSha1       = ''
        Pin               = $Pin
        Provenance        = $Provenance
        ProvenanceProblem = $Problem
        ProvenanceSource  = $(if ($Provenance) { 'file' } else { 'shipped' })
        Reason            = ''
        CheckedUtc        = [datetime]::UtcNow
    }

    $State.Supported = [bool](Test-WtExternalToolSupported)

    if (-not $State.Installed)
    {
        $State.Status = 'Missing'
        return $State
    }

    $State.Bytes = [long](Get-Item -LiteralPath $Path -ErrorAction Ignore).Length
    $State.Sha256 = Get-WtExternalToolHash -Path $Path -Algorithm 'SHA256'
    $State.GitBlobSha1 = Get-WtExternalToolGitBlobHash -Path $Path

    if ($State.Bytes -ne [long]$Pin.Bytes)
    {
        $State.Status = 'Mismatch'
        $State.Reason = "The local file is $($State.Bytes) bytes; the pin records $($Pin.Bytes) bytes."
        return $State
    }

    if ($State.Sha256 -ne [string]$Pin.Sha256)
    {
        $State.Status = 'Mismatch'
        $State.Reason = 'The local file does not match the SHA-256 recorded for this pin.'
        return $State
    }

    $State.Status = 'Ready'
    $State.Ready = $true
    if ($Pin.GitBlobSha1 -and $State.GitBlobSha1 -and $State.GitBlobSha1 -ne [string]$Pin.GitBlobSha1)
    {
        $State.Status = 'Mismatch'
        $State.Ready = $false
        $State.Reason = 'The local file does not match the upstream git blob id recorded for this pin.'
    }

    if (-not $Problem -and -not $Pin.GitBlobSha1)
    {
        $State.Reason = 'The git blob id was not recorded for this pin, so only the SHA-256 was compared.'
    }

    return $State
}

#endregion Provenance and state

#region Download and removal

<#
.SYNOPSIS
    Resolves the newest upstream release to one immutable commit (explicit update only).
.DESCRIPTION
    Three small documents are read from the GitHub API: the latest release tag, the commit
    that tag points at, and the entry point's blob id and size at that commit. The branch
    and the tag are never used as the download target: the download URL is built from the
    resolved commit, so a moving branch cannot change what is executed.

    Called only from an explicit "update" action, never during navigation or refresh.
.OUTPUTS
    An ordered dictionary: Ok, Tag, PublishedUtc, Commit, Bytes, GitBlobSha1, DownloadUrl,
    UpToDate, Reason.
#>
function Resolve-WtExternalToolLatest
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][object]$Spec,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Progress = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Cancel = $null
    )

    if (-not $Spec) { $Spec = Get-WtExternalToolSpec }

    if ($Progress)
    {
        $Progress.Phase = 'resolving'
        $Progress.Total = [long]0
        $Progress.Percent = -1
    }

    $Result = [ordered]@{
        Ok           = $false
        Tag          = ''
        PublishedUtc = ''
        Commit       = ''
        Bytes        = [long]0
        GitBlobSha1  = ''
        DownloadUrl  = ''
        UpToDate     = $false
        Cancelled    = $false
        Reason       = ''
    }

    $Repository = [string]$Spec.Repository
    try
    {
        $Release = Get-WtExternalToolJson -Url ("https://api.github.com/repos/{0}/releases/latest" -f $Repository) -MaxBytes 262144 -Progress $Progress -Cancel $Cancel
        $Tag = [string](Get-WtExternalToolJsonProperty -Document $Release -Name 'tag_name')
        if ([string]::IsNullOrWhiteSpace($Tag))
        {
            $Result.Reason = 'The upstream release document does not name a tag.'
            return $Result
        }
        $Result.Tag = $Tag
        $Result.PublishedUtc = [string](Get-WtExternalToolJsonProperty -Document $Release -Name 'published_at')

        $CommitDocument = Get-WtExternalToolJson -Url ("https://api.github.com/repos/{0}/commits/{1}" -f $Repository, $Tag) -MaxBytes 1048576 -Progress $Progress -Cancel $Cancel
        $Commit = [string](Get-WtExternalToolJsonProperty -Document $CommitDocument -Name 'sha')
        if ($Commit -notmatch '^[0-9a-f]{40}$')
        {
            $Result.Reason = "The upstream commit for tag '$Tag' could not be resolved."
            return $Result
        }
        $Result.Commit = $Commit

        $Path = [string]$Spec.RepositoryPath
        $DirectoryPath = $Path.Substring(0, $Path.LastIndexOf('/'))
        $FileName = $Path.Substring($Path.LastIndexOf('/') + 1)
        $Listing = Get-WtExternalToolJson -Url ("https://api.github.com/repos/{0}/contents/{1}?ref={2}" -f $Repository, $DirectoryPath, $Commit) -MaxBytes 262144 -Progress $Progress -Cancel $Cancel

        $Entry = $null
        foreach ($Item in @($Listing))
        {
            if ([string](Get-WtExternalToolJsonProperty -Document $Item -Name 'name') -eq $FileName)
            {
                $Entry = $Item
                break
            }
        }

        if (-not $Entry)
        {
            $Result.Reason = "The upstream entry point '$Path' is missing at commit $Commit."
            return $Result
        }

        $Result.Bytes = [long](Get-WtExternalToolJsonProperty -Document $Entry -Name 'size')
        $Result.GitBlobSha1 = [string](Get-WtExternalToolJsonProperty -Document $Entry -Name 'sha')
        $Result.DownloadUrl = 'https://raw.githubusercontent.com/{0}/{1}/{2}' -f $Repository, $Commit, $Path
        $Result.UpToDate = ($Commit -eq [string]$Spec.Commit)
        $Result.Ok = $true
        return $Result
    }
    catch
    {
        $Message = $_.Exception.Message
        if ($Message -match '^CANCELLED:')
        {
            $Result.Cancelled = $true
            $Message = $Message -replace '^CANCELLED:\s*', ''
        }

        $Result.Reason = $Message
        return $Result
    }
}

<#
.SYNOPSIS
    Downloads, verifies, publishes and records the upstream file.
.DESCRIPTION
    The sequence is fixed:
      1. one file is downloaded into the staging directory (bounded in size and in time);
      2. its size and its git blob id are compared with what upstream reports for the
         commit (blob id when the runtime can compute SHA-1);
      3. its SHA-256 is compared with the pin (or, for an explicit update, recorded, since
         no such digest exists upstream);
      4. the verified file is published in one step;
      5. the provenance record is written atomically - it is the "ready" marker.
    A failure at any step removes only the staging file and leaves a previously installed
    copy untouched. Nothing is executed here.
.PARAMETER Latest
    Resolve the newest upstream release first and download that commit instead of the
    shipped pin. Only an explicit update action passes this.
.PARAMETER Release
    A release document already resolved and confirmed by the caller. It is used instead of
    resolving again, so the tag, commit and size the user confirmed are the ones that are
    downloaded.
.PARAMETER PinSource
    Written to the provenance record: 'shipped' for the pin in this file,
    'user-update' for a commit the user resolved explicitly.
.OUTPUTS
    An ordered dictionary: Status, Code, Reason, State, Provenance.
#>
function Invoke-WtExternalToolDownload
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param
    (
        [Parameter(Mandatory = $false)][object]$Spec,
        [Parameter(Mandatory = $false)][switch]$Latest,
        [Parameter(Mandatory = $false)][object]$Release,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Progress = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Cancel = $null
    )

    if (-not $Spec) { $Spec = Get-WtExternalToolSpec }
    $Latest = [bool]($Latest -or $Release)

    $Result = [ordered]@{
        Status     = 'failed'
        Code       = ''
        Reason     = ''
        State      = $null
        Provenance = $null
        Plan       = $null
    }

    if (-not (Test-WtExternalToolSupported))
    {
        $Result.Code = 'Unsupported'
        $Result.Reason = 'The upstream tool is a Windows batch script; this platform cannot run it.'
        return $Result
    }

    # Dry run: nothing is resolved, fetched, staged or written. The plan is returned so the
    # caller can state exactly what would happen, in its own words and its own language.
    if (-not $PSCmdlet.ShouldProcess($Spec.FileName, ("download {0} bytes from {1}" -f $Spec.Bytes, $Spec.DownloadUrl)))
    {
        $Result.Status = 'dryrun'
        $Result.Code = 'Preview'
        $Result.Reason = 'Dry run: no download was started.'
        $Result.Plan = [ordered]@{
            Tool      = [string]$Spec.Id
            Update    = [bool]$Latest
            Tag       = [string]$Spec.Tag
            Commit    = [string]$Spec.Commit
            Url       = [string]$Spec.DownloadUrl
            Bytes     = [long]$Spec.Bytes
            Sha256    = [string]$Spec.Sha256
            Target    = (Get-WtExternalToolEntryPointPath -Spec $Spec)
            PinSource = [string]$Spec.PinSource
        }
        return $Result
    }

    $Tag = [string]$Spec.Tag
    $Commit = [string]$Spec.Commit
    $Bytes = [long]$Spec.Bytes
    $Url = [string]$Spec.DownloadUrl
    $PinSource = [string]$Spec.PinSource
    $BlobSha1 = [string]$Spec.GitBlobSha1

    if ($Progress)
    {
        $Progress.Phase = 'resolving'
        if ($Bytes -gt 0) { $Progress.Total = $Bytes }
    }

    if ($Latest)
    {
        if (-not $Release)
        {
            $Release = Resolve-WtExternalToolLatest -Spec $Spec -Progress $Progress -Cancel $Cancel
        }
        if (-not $Release.Ok)
        {
            $Result.Code = 'ResolveFailed'
            $Result.Reason = $Release.Reason
            return $Result
        }
        if ($Release.UpToDate)
        {
            $Result.Code = 'UpToDate'
            $Result.Status = 'succeeded'
            $Result.Reason = "Upstream release $($Release.Tag) is the pin that is already installed."
            $Result.State = Get-WtExternalToolState -Spec $Spec
            return $Result
        }

        $Tag = $Release.Tag
        $Commit = $Release.Commit
        $Bytes = $Release.Bytes
        $Url = $Release.DownloadUrl
        $BlobSha1 = $Release.GitBlobSha1
        $PinSource = 'user-update'
    }

    $MaxBytes = [int]$Spec.MaxBytes
    $TimeoutSeconds = [int]$Spec.TimeoutSeconds
    $MaxRedirects = [int]$Spec.MaxRedirects

    if ($Bytes -gt 0 -and $MaxBytes -gt 0 -and $Bytes -gt $MaxBytes)
    {
        $Result.Code = 'Integrity'
        $Result.Reason = "The pinned artifact ($Bytes bytes) is above the $MaxBytes byte download limit."
        return $Result
    }

    $StagingRoot = Get-WtExternalToolStagingRoot
    $StagingPath = [System.IO.Path]::Combine($StagingRoot, ('{0}.{1}.part' -f [string]$Spec.FileName, [guid]::NewGuid().ToString('n').Substring(0, 12)))

    try
    {
        New-WtDirectory -Path $StagingRoot

        Write-WtLog -Level Information -Message ("Downloading {0} tag {1} commit {2}" -f $Spec.Name, $Tag, $Commit) `
            -Operation 'ExternalTool' -Status 'pending' -NoConsole -Data @{ tool = $Spec.Id; tag = $Tag; commit = $Commit; url = $Url }

        if ($Progress)
        {
            $Progress.Phase = 'downloading'
            $Progress.Total = $Bytes
        }

        $Transfer = Save-WtExternalToolDownload -Url $Url -Path $StagingPath -MaxBytes $MaxBytes -TimeoutSeconds $TimeoutSeconds `
            -MaxRedirects $MaxRedirects -Progress $Progress -Cancel $Cancel

        if ($Progress) { $Progress.Phase = 'verifying' }

        $StagedBytes = [long](Get-Item -LiteralPath $StagingPath).Length
        if ($Transfer.Bytes -ne $StagedBytes)
        {
            throw "INTEGRITY: The download reported $($Transfer.Bytes) bytes but the staging file holds $StagedBytes bytes."
        }

        if ($Bytes -gt 0 -and $StagedBytes -ne $Bytes)
        {
            throw "INTEGRITY: The downloaded file is $StagedBytes bytes; upstream reports $Bytes bytes for this commit."
        }

        if ($BlobSha1)
        {
            $StagedBlob = Get-WtExternalToolGitBlobHash -Path $StagingPath
            if (-not $StagedBlob)
            {
                Write-WtLog -Level Warning -Message 'The git blob id could not be computed on this runtime; the size and SHA-256 checks still apply.' -Operation 'ExternalTool' -NoConsole
            }
            elseif ($StagedBlob -ne $BlobSha1)
            {
                throw "INTEGRITY: The downloaded file's git blob id ($StagedBlob) does not match the pinned id ($BlobSha1)."
            }
        }

        $Sha256 = Get-WtExternalToolHash -Path $StagingPath -Algorithm 'SHA256'
        if (-not $Sha256)
        {
            throw 'INTEGRITY: The downloaded file could not be hashed, so it cannot be marked ready.'
        }

        # The recorded digest is enforced whenever the bytes are supposed to be the shipped
        # pin: for a plain download always, and for a resolved update whenever the commit it
        # resolved to is the shipped commit (a re-download of the pinned version, which must
        # still match the digest recorded for it).
        if (-not $Latest -or ($Commit -eq [string]$Spec.Commit -and -not [string]::IsNullOrWhiteSpace([string]$Spec.Sha256)))
        {
            $Expected = [string]$Spec.Sha256
            if ($Sha256 -ne $Expected)
            {
                throw "INTEGRITY: The downloaded file's SHA-256 ($Sha256) does not match the pinned digest ($Expected)."
            }

            if ($Latest)
            {
                # Same bytes as the shipped pin even though the release moved: keep the shipped
                # provenance wording, which is the accurate one.
                $PinSource = 'shipped'
            }
        }

        if ($Progress) { $Progress.Phase = 'publishing' }

        $Published = Publish-WtExternalToolFile -StagingPath $StagingPath -Path (Get-WtExternalToolEntryPointPath -Spec $Spec)

        $Provenance = [ordered]@{
            schema             = $Script:WtExternalToolProvenanceSchema
            toolId             = [string]$Spec.Id
            name               = [string]$Spec.Name
            repository         = 'https://github.com/{0}' -f [string]$Spec.Repository
            license            = [string]$Spec.License
            licenseUrl         = 'https://github.com/{0}/blob/{1}/LICENSE' -f [string]$Spec.Repository, $Commit
            documentationUrl   = [string]$Spec.DocumentationUrl
            tag                = $Tag
            commit             = $Commit
            repositoryPath     = [string]$Spec.RepositoryPath
            fileName           = [string]$Spec.FileName
            downloadUrl        = $Url
            bytes              = $StagedBytes
            sha256             = $Sha256
            gitBlobSha1        = $(if ($BlobSha1) { $BlobSha1 } else { Get-WtExternalToolGitBlobHash -Path $Published })
            pinSource          = $PinSource
            hashSource         = 'recorded by WindowsTweaker when this pin was installed; upstream publishes no checksum file or signature for this artifact'
            downloadedUtc      = [datetime]::UtcNow.ToString('o')
            downloadedBy       = 'WindowsTweaker {0}' -f (Get-WtAppVersion)
            entryPoint         = 'cmd.exe /c "<file>" <method switches> (one Windows-only activation method per run; no menu is shown)'
            redistributionNote = 'GPL-3.0: redistributing this file carries the GPL-3.0 obligations; WindowsTweaker does not embed or modify it.'
        }

        $null = Write-WtAtomicFile -Path (Get-WtExternalToolProvenancePath) -Value (ConvertTo-WtJson -InputObject $Provenance -Depth 8)

        Write-WtLog -Level Information -Message ("Downloaded and verified {0} tag {1} commit {2} ({3} bytes, sha256 {4})" -f $Spec.Name, $Tag, $Commit, $StagedBytes, $Sha256) `
            -Operation 'ExternalTool' -Status 'succeeded' -NoConsole -Data @{ tool = $Spec.Id; tag = $Tag; commit = $Commit; bytes = $StagedBytes; sha256 = $Sha256 }

        if ($Progress)
        {
            $Progress.Phase = 'done'
        }

        $Result.Status = 'succeeded'
        $Result.Code = $(if ($Latest) { 'Updated' } else { 'Downloaded' })
        $Result.Provenance = $Provenance
        $Result.State = Get-WtExternalToolState -Spec $Spec
        return $Result
    }
    catch
    {
        $Message = $_.Exception.Message
        $Result.Code = 'DownloadFailed'
        if ($Message -match '^INTEGRITY:')
        {
            $Result.Code = 'Integrity'
            $Message = $Message -replace '^INTEGRITY:\s*', ''
        }
        elseif ($Message -match '^NETWORK:')
        {
            $Result.Code = 'Network'
            $Message = $Message -replace '^NETWORK:\s*', ''
        }
        elseif ($Message -match '^RUNTIME:')
        {
            $Result.Code = 'Runtime'
            $Message = $Message -replace '^RUNTIME:\s*', ''
        }
        elseif ($Message -match '^CANCELLED:')
        {
            $Result.Code = 'Cancelled'
            $Message = $Message -replace '^CANCELLED:\s*', ''
        }

        $Result.Reason = $Message
        $Result.State = Get-WtExternalToolState -Spec $Spec

        if ($Result.Code -eq 'Cancelled')
        {
            $Result.Status = 'cancelled'
            Write-WtLog -Level Warning -Message ("Download of {0} was cancelled; the staging file was removed" -f $Spec.Name) `
                -Operation 'ExternalTool' -Status 'failed' -NoConsole -Data @{ tool = $Spec.Id; tag = $Tag; commit = $Commit }
        }
        else
        {
            Write-WtLog -Level Error -Message ("Download of {0} failed: {1}" -f $Spec.Name, $Message) `
                -Operation 'ExternalTool' -Status 'failed' -NoConsole -Data @{ tool = $Spec.Id; tag = $Tag; commit = $Commit; url = $Url }
        }

        return $Result
    }
    finally
    {
        # Only the staging file this call created is removed - a cancelled or failed download
        # never publishes, and never touches the copy that is already installed.
        if (Test-Path -LiteralPath $StagingPath)
        {
            Remove-Item -LiteralPath $StagingPath -Force -ErrorAction Ignore
        }

        if ($Progress)
        {
            $Progress.Phase = 'idle'
        }
    }
}

<#
.SYNOPSIS
    Lists the files a removal would delete (existing ones only).
.DESCRIPTION
    Pure: it reads the filesystem and writes nothing, which is what lets a dry run describe the
    removal exactly - the same list is used by the action itself.
#>
function Get-WtExternalToolRemovableFiles
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ([Parameter(Mandatory = $false)][object]$Spec)

    if (-not $Spec) { $Spec = Get-WtExternalToolSpec }

    $Candidates = @(
        (Get-WtExternalToolProvenancePath)
        (Get-WtExternalToolEntryPointPath -Spec $Spec)
    )

    $StagingRoot = Get-WtExternalToolStagingRoot
    if (Test-Path -LiteralPath $StagingRoot -PathType Container)
    {
        foreach ($File in @(Get-ChildItem -LiteralPath $StagingRoot -Filter '*.part' -File -ErrorAction Ignore))
        {
            $Candidates += $File.FullName
        }
    }

    return @($Candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
}

<#
.SYNOPSIS
    Removes the downloaded file, its staging leftovers and the provenance record.
.DESCRIPTION
    Only paths this feature created are removed, each one named explicitly: no recursive
    delete of a directory the user might have put something else in. The directory itself is
    removed only when it is empty afterwards.
.OUTPUTS
    An ordered dictionary: Status, Removed (paths), Reason.
#>
function Remove-WtExternalToolFiles
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param ([Parameter(Mandatory = $false)][object]$Spec)

    if (-not $Spec) { $Spec = Get-WtExternalToolSpec }

    $Result = [ordered]@{
        Status      = 'succeeded'
        Removed     = @()
        WouldRemove = @()
        Reason      = ''
    }

    $Candidates = @(Get-WtExternalToolRemovableFiles -Spec $Spec)

    $StagingRoot = Get-WtExternalToolStagingRoot

    # Dry run: the same list is reported, and nothing is deleted.
    if (-not $PSCmdlet.ShouldProcess((Get-WtExternalToolRoot), 'remove the downloaded external tool files'))
    {
        $Result.Status = 'dryrun'
        $Result.WouldRemove = @($Candidates)
        $Result.Reason = 'Dry run: no file was removed.'
        return $Result
    }

    foreach ($Path in $Candidates)
    {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { continue }
        try
        {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            $Result.Removed += $Path
        }
        catch
        {
            $Result.Status = 'failed'
            $Result.Reason = "Could not remove '$Path': $($_.Exception.Message)"
            return $Result
        }
    }

    if (Test-Path -LiteralPath $StagingRoot -PathType Container)
    {
        if (@(Get-ChildItem -LiteralPath $StagingRoot -Force -ErrorAction Ignore).Count -eq 0)
        {
            Remove-Item -LiteralPath $StagingRoot -Force -ErrorAction Ignore
        }
    }

    $Root = Get-WtExternalToolRoot
    if (Test-Path -LiteralPath $Root -PathType Container)
    {
        if (@(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Ignore).Count -eq 0)
        {
            Remove-Item -LiteralPath $Root -Force -ErrorAction Ignore
        }
    }

    Write-WtLog -Level Information -Message ("Removed {0} local file(s) for {1}" -f @($Result.Removed).Count, $Spec.Name) `
        -Operation 'ExternalTool' -Status 'succeeded' -NoConsole -Data @{ tool = $Spec.Id; removed = @($Result.Removed) }

    return $Result
}

#endregion Download and removal

#region Windows activation methods

# The Windows-only activation methods this feature offers. Every entry is a switch (or a pair of
# switches) that the pinned upstream revision implements and documents itself:
#
#   * MAS_AIO.cmd at commit 40c74d0d7f42146b1dd1ab59b5c7e836d6a56d1f dispatches on its own command
#     line before it paints any menu (lines 396-403) - '/HWID' to :HWIDActivation, '/Z-' to
#     :TSforgeActivation, '/K-' to :KMSActivation - and exits after that one, so the menu is never
#     reached and no choice has to be made for the user;
#   * '/HWID-NoEditionChange' (line 675) and '/K-NoEditionChange' (line 12081) exist precisely to
#     stop the script from changing the Windows edition. Both are passed, because this feature never
#     allows an edition change;
#   * upstream states at https://massgrave.dev/command_line_switches that "the script will run in
#     unattended mode if any switch is used", so nothing here feeds keystrokes, and
#   * '/S' (silent) is documented but deliberately not passed: it discards the whole console
#     output, and a visible upstream report is what makes a failure diagnosable. The child's
#     streams are never read or logged either way.
#
# The list is closed: only an Id from it can reach a command line. Office, ESU, KMS-Host, APPX,
# edition-change and reset switches are not represented anywhere in this file.
$Script:WtActivationMethods = @(
    @{
        Id            = 'HWID'
        Switch        = '/HWID'
        ExtraSwitches = @('/HWID-NoEditionChange')
        DurationModel = 'Permanent'
        Internet      = 'Required'
        MinBuild      = 10240
        EditionScope  = 'Client'
        Evidence      = 'Pinned MAS_AIO.cmd: line 398 dispatches /HWID; line 675 accepts /HWID-NoEditionChange; lines 684-696 refuse Windows Server and builds below 10240. Documented: massgrave.dev/command_line_switches, massgrave.dev/hwid ("permanent Windows activation for your system hardware").'
    }
    @{
        Id            = 'TSforge'
        Switch        = '/Z-Windows'
        ExtraSwitches = @()
        DurationModel = 'Permanent'
        Internet      = 'AutomaticMethod'
        MinBuild      = 7600
        EditionScope  = 'AnyWindows'
        Evidence      = 'Pinned MAS_AIO.cmd: line 399 dispatches /Z-; the TSforge block accepts /Z-Windows (Windows only, never ESU/Office) and selects the activation method itself. Documented: massgrave.dev/tsforge ("permanent until a Windows reinstall or a major feature upgrade"; Internet needed only for StaticCID, the default from build 26100).'
    }
    @{
        Id            = 'OnlineKMS'
        Switch        = '/K-Windows'
        ExtraSwitches = @('/K-NoEditionChange')
        DurationModel = 'TimeLimited'
        Internet      = 'Required'
        MinBuild      = 7600
        EditionScope  = 'AnyWindows'
        Evidence      = 'Pinned MAS_AIO.cmd: line 400 dispatches /K-; the Online KMS block accepts /K-Windows and /K-NoEditionChange (line 12081). Documented: massgrave.dev/online_kms ("KMS activates Windows / Office for 180 Days", renewal task gives lifetime activation; massgrave.dev/command_line_switches for both switches).'
    }
)

<#
.SYNOPSIS
    Returns the Windows-only activation methods, or one of them by Id.
.DESCRIPTION
    Only ids that appear in the table above are ever returned, so an id that arrives from a
    settings file or a caller cannot become an arbitrary command-line switch.
.OUTPUTS
    An array of method dictionaries, or one dictionary, or $null for an unknown id.
#>
function Get-WtWindowsActivationMethod
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string]$Id = '')

    if (-not $Id)
    {
        return @($Script:WtActivationMethods)
    }

    foreach ($Method in $Script:WtActivationMethods)
    {
        if ([string]$Method.Id -eq $Id) { return $Method }
    }

    return $null
}

<#
.SYNOPSIS
    Reads the Windows activation method the user selected ('' when none is selected).
.DESCRIPTION
    The setting lives in the user settings file next to the interface preferences. An id this
    build does not know - an older or a newer release wrote it - is reported as "nothing selected"
    instead of being passed through.
.OUTPUTS
    A method dictionary, or $null.
#>
function Get-WtWindowsActivationMethodSetting
{
    [CmdletBinding()]
    param ()

    $Id = ''
    try
    {
        $Id = [string](Read-WtSettings).ActivationMethod
    }
    catch
    {
        $Id = ''
    }

    if (-not $Id) { return $null }
    return (Get-WtWindowsActivationMethod -Id $Id)
}

<#
.SYNOPSIS
    Stores the selected Windows activation method.
.DESCRIPTION
    Refuses an id that is not in the table (returning $false) so a typo cannot be persisted. An
    empty id clears the selection: this feature never picks a method for the user, and it never
    substitutes a permanent method for a time-limited request.
.OUTPUTS
    [bool] whether the setting was written.
#>
function Set-WtWindowsActivationMethodSetting
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Id)

    if ($Id -and -not (Get-WtWindowsActivationMethod -Id $Id))
    {
        return $false
    }

    $Settings = Read-WtSettings
    $Settings.ActivationMethod = $Id
    Write-WtSettings -Settings $Settings
    return $true
}

<#
.SYNOPSIS
    Describes the installed Windows edition the method checks are made against.
.DESCRIPTION
    The name is assembled from three raw sources so none of them is trusted alone:
      * the registry product name (ProductName) is kept as the raw source, but it is not the
        basis for the generation claim - a legacy "Windows 10 IoT Enterprise" string can outlive
        an installed Windows 11 build;
      * the build number decides the Windows generation (>= 22000 is Windows 11);
      * the edition id (EditionID), when readable, decides the edition tokens (Professional,
        Core, Enterprise, IoT, LTSC, Server, Evaluation, ...).
    Both raw strings are preserved in the result for diagnostics. The licensing record's product
    name is a fallback for the search text only.
.OUTPUTS
    An ordered dictionary: Name, Generation, RegistryName, LicensingName, EditionId, Build,
    IsServer, IsEvaluation, Known.
#>
function Get-WtWindowsActivationEdition
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][AllowNull()][object]$License = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Environment = $null
    )

    $RegistryName = ''
    $Build = 0
    $EditionId = ''
    if ($Environment)
    {
        if ($Environment.OSName) { $RegistryName = [string]$Environment.OSName }
        if ($null -ne $Environment.OSBuild) { $Build = [int]$Environment.OSBuild }
        if ($Environment.OSEditionID) { $EditionId = [string]$Environment.OSEditionID }
    }

    $LicensingName = ''
    if ($License -and $License.Inventory -and -not $License.Inventory.Unreadable -and $License.Inventory.Active)
    {
        $LicensingName = [string]$License.Inventory.Active.ProductName
    }

    # The generation comes from the build, never from the (potentially legacy) ProductName string.
    $Generation = 'Unknown'
    if ($Build -ge 22000) { $Generation = 'Windows11' }
    elseif ($Build -ge 10240) { $Generation = 'Windows10' }

    # The display name: generation plus the documented edition label for EditionID, with the
    # registry raw name as the fallback when the edition id is unknown.
    $EditionLabel = Get-WtEditionDisplayLabel -EditionId $EditionId
    if ($Generation -ne 'Unknown' -and $EditionLabel)
    {
        $GenerationText = ($Generation -replace '(?i)^windows', 'Windows ')
        $Name = $GenerationText + ' ' + $EditionLabel
    }
    else
    {
        $Name = $RegistryName
        if (-not $Name) { $Name = $LicensingName }
    }

    $Search = ($RegistryName + ' ' + $LicensingName + ' ' + $EditionId).Trim()

    $Result = [ordered]@{
        Name         = $Name
        Generation   = $Generation
        RegistryName = $RegistryName
        LicensingName = $LicensingName
        EditionId    = $EditionId
        Build        = $Build
        IsServer     = [bool]($Search -match '(?i)\bserver\b')
        IsEvaluation = [bool]($Search -match '(?i)eval')
        Known        = [bool]($Name -or $Build -gt 0)
    }

    return $Result
}

<#
.SYNOPSIS
    Reports whether one activation method may be used on the installed edition.
.DESCRIPTION
    Every rule comes from upstream material read at the pinned commit; nothing is inferred:
      ServerEdition     - HWID only supports Windows 10/11 client (upstream refuses Server and
                          points at TSforge instead), so a Windows Server edition is not offered it;
      EvaluationEdition - upstream states an evaluation edition cannot be activated beyond its
                          evaluation period, and that TSforge only resets that period, so none of
                          the three permanent/time-limited models would hold here;
      BuildTooOld       - below the method's minimum build (10240 for HWID, 7600 elsewhere);
      BuildUnknown      - the build number could not be read, which is never treated as "new
                          enough";
      EditionUnknown    - neither the registry nor the licensing record named the edition;
      NotWindows        - the pinned script only runs on Windows.
    The caller shows the status; it never falls back to another method after a refusal or a
    failure.
.OUTPUTS
    An ordered dictionary: Status, Compatible, MethodId.
#>
function Test-WtWindowsActivationMethodCompatibility
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Method,
        [Parameter(Mandatory = $true)][object]$Edition
    )

    $Result = [ordered]@{
        Status     = 'Compatible'
        Compatible = $true
        MethodId   = [string]$Method.Id
    }

    $Status = 'Compatible'

    if (-not (Test-WtExternalToolSupported))
    {
        $Status = 'NotWindows'
    }
    elseif (-not $Edition.Known)
    {
        $Status = 'EditionUnknown'
    }
    elseif ([int]$Method.MinBuild -gt 0 -and [int]$Edition.Build -le 0)
    {
        $Status = 'BuildUnknown'
    }
    elseif ([int]$Method.MinBuild -gt 0 -and [int]$Edition.Build -lt [int]$Method.MinBuild)
    {
        $Status = 'BuildTooOld'
    }
    elseif ($Edition.IsEvaluation)
    {
        $Status = 'EvaluationEdition'
    }
    elseif ($Edition.IsServer -and [string]$Method.EditionScope -eq 'Client')
    {
        $Status = 'ServerEdition'
    }

    $Result.Status = $Status
    $Result.Compatible = ($Status -eq 'Compatible')
    return $Result
}

#endregion Windows activation methods

#region Launch

<#
.SYNOPSIS
    Reports whether this session is already elevated.
.DESCRIPTION
    Only used to decide whether an explicit UAC handoff is needed; a false answer on a
    non-Windows runtime is accurate (there is nothing to elevate, and the tool cannot run
    there at all).
#>
function Test-WtIsElevatedProcess
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    if (-not (Test-WtIsWindows)) { return $false }

    try
    {
        $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $Principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $Identity
        return [bool]$Principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch
    {
        return $false
    }
}

<#
.SYNOPSIS
    Builds the command line that runs the downloaded script for one Windows activation method.
.DESCRIPTION
    The entry point is the documented one: the batch file itself, run through the command
    interpreter with /c, plus the switches of exactly one method from the closed table above. The
    switches make upstream run that method in unattended mode and exit, so its interactive menu is
    never shown and no keystroke is ever fed to it.

    The method is resolved from the table by Id: a caller cannot hand in a switch of its own, and an
    unknown or empty Id produces a plan that is refused rather than a command line without a choice.

    The path must be the file this feature downloaded, inside its own directory. A path that
    contains a double quote, a percent sign or a line break is refused instead of being
    escaped: cmd.exe expands %NAME% inside double quotes, so such a path could not be passed
    safely.
.OUTPUTS
    An ordered dictionary: Ok, Reason, FilePath, ArgumentList, WorkingDirectory, Elevated,
    CommandLine, MethodId, Switches.
#>
function Get-WtExternalToolLaunchPlan
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][object]$Spec,
        [Parameter(Mandatory = $false)][string]$ToolPath = '',
        [Parameter(Mandatory = $false)][string]$Interpreter = '',
        [Parameter(Mandatory = $false)][AllowNull()][object]$Elevated = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Method = $null
    )

    if (-not $Spec) { $Spec = Get-WtExternalToolSpec }
    if (-not $ToolPath) { $ToolPath = Get-WtExternalToolEntryPointPath -Spec $Spec }

    $Plan = [ordered]@{
        Ok               = $false
        Reason           = ''
        FilePath         = ''
        ArgumentList     = @()
        WorkingDirectory = ''
        Elevated         = [bool]$Elevated
        CommandLine      = ''
        MethodId         = ''
        Switches         = @()
    }

    $MethodId = ''
    if ($Method)
    {
        if ($Method -is [string]) { $MethodId = $Method } else { $MethodId = [string]$Method.Id }
    }
    $Resolved = Get-WtWindowsActivationMethod -Id $MethodId
    $List = @($Resolved)
    # Exactly one method from the table must match: an empty id returns the whole table, and an
    # array can never be a command line.
    if ($List.Count -ne 1 -or [string]$List[0].Id -ne $MethodId)
    {
        $Plan.Reason = 'No Windows activation method is selected, so no activation command was composed.'
        return $Plan
    }
    $Resolved = $List[0]

    $Plan.MethodId = [string]$Resolved.Id
    $Plan.Switches = @([string]$Resolved.Switch) + @($Resolved.ExtraSwitches)

    if ($null -eq $Elevated)
    {
        $Plan.Elevated = [bool](Test-WtIsElevatedProcess)
    }

    $Root = [System.IO.Path]::GetFullPath((Get-WtExternalToolRoot)).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $Full = [System.IO.Path]::GetFullPath($ToolPath)

    if (-not ($Full.StartsWith(($Root + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)))
    {
        $Plan.Reason = 'The selected file is not inside the directory WindowsTweaker downloaded it to.'
        return $Plan
    }

    if (-not (Test-Path -LiteralPath $Full -PathType Leaf))
    {
        $Plan.Reason = 'The downloaded file is not present.'
        return $Plan
    }

    if ([System.IO.Path]::GetFileName($Full) -ne [string]$Spec.FileName)
    {
        $Plan.Reason = "Only the pinned entry point ('$($Spec.FileName)') is launched."
        return $Plan
    }

    foreach ($Forbidden in '"', '%', "`r", "`n")
    {
        if ($Full.Contains($Forbidden))
        {
            $Plan.Reason = 'The download path contains a character that cannot be passed to the command interpreter safely.'
            return $Plan
        }
    }

    $Command = if ($Interpreter) { $Interpreter } elseif ($env:ComSpec) { [string]$env:ComSpec } else { 'cmd.exe' }

    $Plan.FilePath = $Command
    $Plan.ArgumentList = @('/c', ('"{0}"' -f $Full)) + @($Plan.Switches)
    $Plan.WorkingDirectory = [System.IO.Path]::GetDirectoryName($Full)
    $Plan.CommandLine = ('{0} /c "{1}" {2}' -f $Command, $Full, (@($Plan.Switches) -join ' ')).TrimEnd()
    $Plan.Ok = $true
    return $Plan
}

<#
.SYNOPSIS
    Starts one console process, optionally through an explicit UAC handoff.
.DESCRIPTION
    This is the only place a process is started for this feature. It is a separate function
    so tests can replace exactly this seam and observe the plan instead of running it.

    The child gets its own console window (no -NoNewWindow): the upstream script and any console
    it opens need one, and its output must never be mixed into the WindowsTweaker screen.

    The function deliberately does not wait: an exit here means the process it started ended, which
    is not the same as the operation ending - upstream relaunches itself through the command
    interpreter or through UAC in several situations, and the launcher then exits long before the
    activation does. Callers observe the operation with Wait-WtWindowsActivationCompletion.

    Elevation is a handoff, never a silent retry: a refused UAC prompt comes back as
    Cancelled, and nothing is started a second time.
.OUTPUTS
    An ordered dictionary: Started, Cancelled, Reason, Process, ProcessId.
#>
function Invoke-WtExternalToolProcess
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $false)][string]$WorkingDirectory = '',
        [Parameter(Mandatory = $false)][bool]$Elevate = $false
    )

    $Result = [ordered]@{
        Started   = $false
        Cancelled = $false
        Reason    = ''
        Process   = $null
        ProcessId = 0
    }

    $Arguments = @{}
    $Arguments['FilePath'] = $FilePath
    $Arguments['ArgumentList'] = $ArgumentList
    $Arguments['PassThru'] = $true
    if ($WorkingDirectory) { $Arguments['WorkingDirectory'] = $WorkingDirectory }
    if ($Elevate) { $Arguments['Verb'] = 'RunAs' }

    try
    {
        $Process = Start-Process @Arguments -ErrorAction Stop
    }
    catch
    {
        $Exception = $_.Exception
        $Base = $Exception.GetBaseException()

        if ($Base -is [System.ComponentModel.Win32Exception] -and ([int]$Base.NativeErrorCode -eq 1223 -or [string]$Base.Message -match 'operation was canceled by the user'))
        {
            $Result.Cancelled = $true
            $Result.Reason = 'The elevation prompt was refused, so nothing was started.'
            return $Result
        }

        $Result.Reason = $Base.Message
        return $Result
    }

    $Result.Started = $true
    $Result.Process = $Process

    if (-not $Process)
    {
        # Without a process object the process id is unknown, and the lifetime is tracked from the
        # process table alone (or reported as unobserved). The launch itself stands.
        $Result.Reason = 'The process was started but no handle to it could be observed.'
        return $Result
    }

    try
    {
        $Result.ProcessId = [int]$Process.Id
    }
    catch
    {
        $Result.ProcessId = 0
    }

    return $Result
}

#endregion Launch

#region Operation lifetime

<#
.SYNOPSIS
    Reads one snapshot of the process table (id, parent id, creation time).
.DESCRIPTION
    The table is what makes an operation's real lifetime observable: a console script that
    relaunches itself - through cmd.exe, through conhost.exe or through an elevation prompt -
    leaves the process that was started behind, and only the parent chain shows that the work
    moved elsewhere. Windows only, and $null when the table cannot be read: callers then report
    "completion unknown" instead of assuming the operation ended with its launcher.
.OUTPUTS
    An array of objects with ProcessId, ParentProcessId and StartUtc, or $null.
#>
function Get-WtExternalToolProcessTable
{
    [CmdletBinding()]
    param ()

    if (-not (Test-WtIsWindows)) { return $null }

    try
    {
        $Rows = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, CreationDate -ErrorAction Stop)
    }
    catch
    {
        return $null
    }

    if ($Rows.Count -eq 0) { return $null }

    $Table = [System.Collections.Generic.List[object]]::new()
    foreach ($Row in $Rows)
    {
        $Start = [datetime]::MinValue
        try { $Start = [datetime]$Row.CreationDate } catch { $Start = [datetime]::MinValue }
        $Table.Add([pscustomobject]@{
                ProcessId       = [int]$Row.ProcessId
                ParentProcessId = [int]$Row.ParentProcessId
                StartUtc        = $Start
            })
    }

    return $Table.ToArray()
}

<#
.SYNOPSIS
    Expands a process-table snapshot into every member of one process tree.
.DESCRIPTION
    Pure, so the expansion can be verified against a fixture table. The walk is repeated to a fixed
    point because an intermediate process (the command interpreter or the conhost that performs a
    relaunch) is usually already gone by the time the elevated child is looked for; the child's
    parent id still points at it, so only accumulating the ids finds the grandchild.

    -RootIds takes the whole seed set, not one id: a caller that polls repeatedly keeps every id it
    has ever seen in the tree, which is what keeps a grandchild reachable after its parent left the
    table. A member whose creation time predates the root cannot belong to it (a recycled process
    id), and is dropped rather than counted as part of the operation.
.OUTPUTS
    An array of table rows, the seed rows included when the snapshot still holds them.
#>
function Get-WtActivationProcessTree
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Table,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][int[]]$RootIds,
        [Parameter(Mandatory = $false)][AllowNull()][object]$RootStartUtc = $null
    )

    $Members = [System.Collections.Generic.List[object]]::new()
    if (-not $Table) { return $Members.ToArray() }

    $Ids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($RootId in @($RootIds)) { $null = $Ids.Add([int]$RootId) }

    $Grew = $true
    while ($Grew)
    {
        $Grew = $false
        foreach ($Row in $Table)
        {
            if ($Ids.Contains([int]$Row.ParentProcessId) -and $Ids.Add([int]$Row.ProcessId))
            {
                $Grew = $true
            }
        }
    }

    $Floor = [datetime]::MinValue
    if ($RootStartUtc) { $Floor = ([datetime]$RootStartUtc).AddSeconds(-1) }

    foreach ($Row in $Table)
    {
        if (-not $Ids.Contains([int]$Row.ProcessId)) { continue }
        if ($Floor -ne [datetime]::MinValue -and $Row.StartUtc -and $Row.StartUtc -lt $Floor) { continue }
        $Members.Add($Row)
    }

    return $Members.ToArray()
}

<#
.SYNOPSIS
    Observes the real lifetime of one activation operation.
.DESCRIPTION
    Two signals are used together, because neither is sufficient on its own:
      * the started process object says whether the *launcher* exited, and carries its exit code;
      * the process table says whether anything the launcher left behind is still running.
    Completion is 'Completed' only when the launcher is gone *and* no member of its tree is left. A
    launcher that exits while its detached child keeps working is 'Unknown' (with the child count
    in Remaining) - that is exactly the observed bug where a wrapper reported success while the
    upstream console was still open. When the process table cannot be read at all, the answer is
    'Unknown' as well: a detached child cannot be ruled out, so completion is not claimed.

    -TableSource exists so the whole classification can be driven from inert fixtures; production
    callers use the default Windows process table.
.OUTPUTS
    An ordered dictionary: Completion (Completed/Unknown/Timeout), ExitCode, Remaining, Reason,
    ObservedSeconds, Elapsed.
#>
function Wait-WtWindowsActivationCompletion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][int]$RootProcessId,
        [Parameter(Mandatory = $false)][AllowNull()][object]$RootStartUtc = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Process = $null,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 1800,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock]$TableSource = $null,
        [Parameter(Mandatory = $false)][int]$PollMilliseconds = 1000,
        [Parameter(Mandatory = $false)][switch]$NoSleep
    )

    if (-not $TableSource) { $TableSource = { Get-WtExternalToolProcessTable } }

    $Result = [ordered]@{
        Completion      = 'Unknown'
        ExitCode        = $null
        Remaining       = 0
        Members         = @()
        Reason          = ''
        ObservedSeconds = 0
        Elapsed         = $false
    }

    if ($RootProcessId -le 0 -and -not $Process)
    {
        $Result.Reason = 'The operation could not be identified, so its completion could not be observed.'
        return $Result
    }

    $Started = [datetime]::UtcNow
    $Deadline = $Started.AddSeconds([math]::Max(1, $TimeoutSeconds))
    $Poll = [math]::Max(50, $PollMilliseconds)
    $ExitCode = $null

    # Every process id this tree has ever contained. Kept across polls because an intermediate
    # process (the one that performs a relaunch) disappears before its child does, and without the
    # accumulated set that child could no longer be traced back to the root.
    $Known = [System.Collections.Generic.HashSet[int]]::new()
    $null = $Known.Add($RootProcessId)

    while ($true)
    {
        if ($Process)
        {
            try
            {
                if ($Process.HasExited)
                {
                    try { $ExitCode = [int]$Process.ExitCode } catch { $ExitCode = $null }
                }
            }
            catch
            {
                # A process started through the shell (elevation handoff) may have no usable handle.
                # The process table answers instead, so the handle failure is intentionally ignored.
                Write-WtLog -Level Debug -Message 'The started process handle was unreadable; the process table answers.' -NoConsole
            }
        }

        $Table = & $TableSource

        if ($null -eq $Table)
        {
            $Result.ObservedSeconds = [int][math]::Max(0, ([datetime]::UtcNow - $Started).TotalSeconds)
            $Result.ExitCode = $ExitCode
            $Result.Completion = 'Unknown'
            $Result.Members = @($Known)
            $Result.Reason = 'The process table could not be read, so a detached child cannot be ruled out.'
            return $Result
        }

        $Current = @{}
        foreach ($Row in $Table) { $Current[[int]$Row.ProcessId] = $Row }

        foreach ($Row in @(Get-WtActivationProcessTree -Table $Table -RootIds @($Known) -RootStartUtc $RootStartUtc))
        {
            $null = $Known.Add([int]$Row.ProcessId)
        }

        $RootAlive = $false
        if ($Current.ContainsKey($RootProcessId))
        {
            $RootRow = $Current[$RootProcessId]
            $RootAlive = $true
            if ($RootStartUtc -and $RootRow.StartUtc -and $RootRow.StartUtc -ne [datetime]::MinValue)
            {
                $Skew = [math]::Abs(([datetime]$RootRow.StartUtc - [datetime]$RootStartUtc).TotalSeconds)
                $RootAlive = ($Skew -lt 2)
            }
        }

        $Remaining = 0
        foreach ($Id in @($Known))
        {
            if ($Id -eq $RootProcessId) { continue }
            if (-not $Current.ContainsKey($Id)) { continue }
            $MemberRow = $Current[$Id]
            if ($RootStartUtc -and $MemberRow.StartUtc -and $MemberRow.StartUtc -ne [datetime]::MinValue)
            {
                # A member created before the operation started is a recycled process id.
                if ($MemberRow.StartUtc -lt ([datetime]$RootStartUtc).AddSeconds(-1)) { continue }
            }
            $Remaining++
        }

        $Result.Remaining = $Remaining
        $Result.Members = @($Known)
        $Result.ObservedSeconds = [int][math]::Max(0, ([datetime]::UtcNow - $Started).TotalSeconds)

        if (-not $RootAlive -and $Remaining -eq 0)
        {
            $Result.Completion = 'Completed'
            $Result.Elapsed = $false
            $Result.ExitCode = $ExitCode
            if ($null -eq $Result.ExitCode -and $Process)
            {
                try { $Result.ExitCode = [int]$Process.ExitCode } catch { $Result.ExitCode = $null }
            }
            return $Result
        }

        if ([datetime]::UtcNow -ge $Deadline)
        {
            $Result.Completion = 'Timeout'
            $Result.Elapsed = $true
            $Result.ExitCode = $ExitCode
            $Result.Reason = 'The operation was still running when its wait deadline passed.'
            return $Result
        }

        if (-not $NoSleep) { Start-Sleep -Milliseconds $Poll }
    }
}

<#
.SYNOPSIS
    Path of the record that describes the operation that may still be running.
.DESCRIPTION
    Inside the tool's own directory in the WindowsTweaker data root, next to the download it
    describes.
#>
function Get-WtWindowsActivationRecordPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    return [System.IO.Path]::Combine((Get-WtExternalToolRoot), 'activation-operation.json')
}

<#
.SYNOPSIS
    Reads the activation operation record ($null when there is none that can be trusted).
#>
function Read-WtWindowsActivationRecord
{
    [CmdletBinding()]
    param ()

    $Path = Get-WtWindowsActivationRecordPath
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    try
    {
        $Raw = Read-WtTextFile -Path $Path
        if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
        $Parsed = ConvertFrom-WtJson -Text $Raw -Depth 6
        if (-not $Parsed) { return $null }
        if ([string](Get-WtExternalToolJsonProperty -Document $Parsed -Name 'schema') -ne 'windows-tweaker.activation-operation/1') { return $null }
        return $Parsed
    }
    catch
    {
        return $null
    }
}

<#
.SYNOPSIS
    Writes the activation operation record atomically.
#>
function Write-WtWindowsActivationRecord
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Record)

    New-WtDirectory -Path (Get-WtExternalToolRoot)
    $null = Write-WtAtomicFile -Path (Get-WtWindowsActivationRecordPath) -Value (ConvertTo-WtJson -InputObject $Record -Depth 6)
}

<#
.SYNOPSIS
    Removes the activation operation record.
#>
function Clear-WtWindowsActivationRecord
{
    [CmdletBinding()]
    param ()

    $Path = Get-WtWindowsActivationRecordPath
    if (Test-Path -LiteralPath $Path -PathType Leaf)
    {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Ignore
    }
}

<#
.SYNOPSIS
    Reports whether an activation operation may still be running.
.DESCRIPTION
    The record written when an activation starts is the second half of the duplicate guard: the
    first half is the in-process flag, which a returned TUI or a new session does not carry. The
    record is judged against the live process table, so it stops blocking as soon as the tree it
    names is gone, and it never blocks for a record that reports a finished operation.

    A record whose state cannot be checked (the process table is unreadable) blocks only while it is
    younger than MaxAgeHours; after that it is reported as stale instead of locking the action
    forever. Nothing is deleted here - the caller decides, and Clear-WtWindowsActivationRecord is
    the only deletion.
.OUTPUTS
    An ordered dictionary: Active, Stale, Record, Reason, Remaining.
#>
function Test-WtWindowsActivationActive
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock]$TableSource = $null,
        [Parameter(Mandatory = $false)][int]$MaxAgeHours = 12
    )

    if (-not $TableSource) { $TableSource = { Get-WtExternalToolProcessTable } }

    $Result = [ordered]@{
        Active    = $false
        Stale     = $false
        Record    = $null
        Reason    = ''
        Remaining = 0
    }

    $Record = Read-WtWindowsActivationRecord
    if (-not $Record) { return $Result }

    $Result.Record = $Record

    $Completion = [string](Get-WtExternalToolJsonProperty -Document $Record -Name 'completion')
    if ($Completion -eq 'completed' -or $Completion -eq 'cancelled' -or $Completion -eq 'refused')
    {
        $Result.Reason = 'The recorded operation finished.'
        return $Result
    }

    $LaunchedUtc = [datetime]::MinValue
    $RawLaunched = [string](Get-WtExternalToolJsonProperty -Document $Record -Name 'launchedUtc')
    if ($RawLaunched)
    {
        try { $LaunchedUtc = ([datetime]$RawLaunched).ToUniversalTime() } catch { $LaunchedUtc = [datetime]::MinValue }
    }

    $RootId = 0
    $RawRoot = Get-WtExternalToolJsonProperty -Document $Record -Name 'rootPid'
    if ($null -ne $RawRoot) { $RootId = [int]$RawRoot }

    $RootStart = $null
    $RawStart = [string](Get-WtExternalToolJsonProperty -Document $Record -Name 'rootStartUtc')
    if ($RawStart)
    {
        try { $RootStart = ([datetime]$RawStart).ToUniversalTime() } catch { $RootStart = $null }
    }

    $Table = & $TableSource
    if ($null -eq $Table)
    {
        $Age = [double]::MaxValue
        if ($LaunchedUtc -ne [datetime]::MinValue) { $Age = ([datetime]::UtcNow - $LaunchedUtc).TotalHours }

        if ($Age -lt $MaxAgeHours)
        {
            # It may still be running, and nothing can prove otherwise: duplicating it is the
            # riskier answer.
            $Result.Active = $true
            $Result.Reason = 'The record could not be checked against the process table.'
            return $Result
        }

        $Result.Stale = $true
        $Result.Reason = 'The record could not be checked and is older than the staleness bound.'
        return $Result
    }

    if ($RootId -le 0)
    {
        $Result.Reason = 'The record names no process, so it cannot be checked.'
        $Result.Stale = $true
        return $Result
    }

    $Current = @{}
    foreach ($Row in $Table) { $Current[[int]$Row.ProcessId] = $Row }

    # The seed set is the recorded root plus every process id the last observation saw in the tree:
    # an intermediate process may already be gone, and the ids are what keeps a grandchild traceable.
    $Known = [System.Collections.Generic.HashSet[int]]::new()
    $null = $Known.Add($RootId)
    $Observed = Get-WtExternalToolJsonProperty -Document $Record -Name 'observedPids'
    foreach ($Entry in @($Observed))
    {
        if ($null -eq $Entry) { continue }
        $null = $Known.Add([int]$Entry)
    }

    foreach ($Row in @(Get-WtActivationProcessTree -Table $Table -RootIds @($Known) -RootStartUtc $RootStart))
    {
        $null = $Known.Add([int]$Row.ProcessId)
    }

    $Alive = 0
    foreach ($Id in @($Known))
    {
        if (-not $Current.ContainsKey($Id)) { continue }
        $Row = $Current[$Id]
        if ($RootStart -and $Row.StartUtc -and $Row.StartUtc -ne [datetime]::MinValue)
        {
            if ($Row.StartUtc -lt ([datetime]$RootStart).AddSeconds(-1)) { continue }
        }
        $Alive++
    }

    $Result.Remaining = $Alive
    if ($Alive -gt 0)
    {
        $Result.Active = $true
        $Result.Reason = 'A process from the recorded operation is still running.'
        return $Result
    }

    $Result.Reason = 'The recorded operation is no longer running.'
    return $Result
}

#endregion Operation lifetime

#region Launch

<#
.SYNOPSIS
    Reports whether a launch is already in progress.
#>
function Test-WtExternalToolLaunching
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    return [bool]$Script:WtExternalToolLaunching
}

<#
.SYNOPSIS
    Runs one Windows activation method of the verified local copy of the upstream tool.
.DESCRIPTION
    Preconditions, in order: the platform can run the tool, a method from the closed table is
    selected, no operation is already running (neither in this process nor through a record that
    names a process which is still alive), and the local copy is verified against its pin. Then the
    console-owning caller releases the terminal, rehearses the plan, and hands the process off (with
    an explicit UAC prompt when the session is not elevated).

    The switches of the selected method make upstream run that one workflow in unattended mode and
    exit, so its menu is never shown, no keystroke is sent and no other operation (Office, ESU,
    edition change, KVM host, reset) is reachable from here. Nothing falls back to another method:
    a refusal or a failure is reported as it is.

    The return value deliberately separates four things that are not the same:
      * Started  - a process was created;
      * Completion - the operation's lifetime was observed to its end (Completed), could not be
        observed (Unknown), or was still running at the deadline (Timeout);
      * ExitCode - what the launcher returned, which says nothing about the licensing state;
      * Status   - 'succeeded' only when completion was observed; 'unknown' when it was not.
    Whether Windows is activated afterwards is answered by re-reading the licensing record, which
    the caller does.
.PARAMETER Method
    A method dictionary from Get-WtWindowsActivationMethods, or the id of one.
.PARAMETER Elevated
    Whether this session is already elevated. $null means "probe it".
.PARAMETER TimeoutSeconds
    How long the operation's lifetime is observed before the answer becomes 'Timeout'.
.OUTPUTS
    An ordered dictionary: Status (succeeded, unknown, refused, failed, cancelled), Code, Reason,
    Plan, Method, Started, ExitCode, Completion, CompletionDetermined, Remaining, RootProcessId.
#>
function Start-WtWindowsActivation
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param
    (
        [Parameter(Mandatory = $false)][object]$Spec,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Method = $null,
        [Parameter(Mandatory = $false)][string]$ToolPath = '',
        [Parameter(Mandatory = $false)][AllowNull()][object]$Elevated = $null,
        [Parameter(Mandatory = $false)][string]$Interpreter = '',
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 1800,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock]$TableSource = $null
    )

    if (-not $Spec) { $Spec = Get-WtExternalToolSpec }

    $Result = [ordered]@{
        Status               = 'refused'
        Code                 = ''
        Reason               = ''
        Plan                 = $null
        Method               = $null
        Started              = $false
        ExitCode             = $null
        Completion           = 'NotStarted'
        CompletionDetermined = $false
        Remaining            = 0
        RootProcessId        = 0
    }

    $MethodId = ''
    if ($Method)
    {
        if ($Method -is [string]) { $MethodId = $Method } else { $MethodId = [string]$Method.Id }
    }
    # Re-resolved from the table: a caller can pass an id, and an id that is not in the table - or a
    # method object carrying anything else - never reaches a command line. An empty id is the whole
    # table, which is not a single method.
    $Resolved = Get-WtWindowsActivationMethod -Id $MethodId
    $List = @($Resolved)
    if ($List.Count -ne 1 -or [string]$List[0].Id -ne $MethodId)
    {
        $Result.Code = 'NoMethod'
        $Result.Reason = 'No Windows activation method is selected, so nothing was started.'
        return $Result
    }
    $Resolved = $List[0]
    $Result.Method = $Resolved

    if (-not (Test-WtExternalToolSupported))
    {
        $Result.Code = 'Unsupported'
        $Result.Reason = 'The upstream tool is a Windows batch script; this platform cannot run it.'
        return $Result
    }

    if ($Script:WtExternalToolLaunching)
    {
        $Result.Code = 'AlreadyLaunched'
        $Result.Reason = 'An activation is already in progress in this session; a second one is not started.'
        return $Result
    }

    $Active = Test-WtWindowsActivationActive -TableSource $TableSource
    if ($Active.Active)
    {
        $Result.Code = 'OperationActive'
        $Result.Reason = 'A previous activation may still be running, so a second one was not started.'
        return $Result
    }

    $State = Get-WtExternalToolState -Spec $Spec
    if (-not $State.Ready)
    {
        $Result.Code = $(if ($State.Installed) { 'Integrity' } else { 'NotDownloaded' })
        $Result.Reason = if ($State.Reason) { $State.Reason } else { 'The downloaded file is not present or has not been verified.' }
        return $Result
    }

    $Plan = Get-WtExternalToolLaunchPlan -Spec $Spec -ToolPath $(if ($ToolPath) { $ToolPath } else { $State.Path }) -Interpreter $Interpreter -Elevated $Elevated -Method $Resolved
    $Result.Plan = $Plan
    if (-not $Plan.Ok)
    {
        $Result.Code = 'LaunchPlan'
        $Result.Reason = $Plan.Reason
        return $Result
    }

    # A dry run is refused here, after the plan exists: the caller can then show exactly what
    # would have been started. Nothing is spawned, elevated or observed.
    if (-not $PSCmdlet.ShouldProcess($Plan.CommandLine, ('run the {0} Windows activation method' -f $Resolved.Id)))
    {
        $Result.Status = 'refused'
        $Result.Code = 'DryRun'
        $Result.Reason = 'Dry run: the activation was not started.'
        return $Result
    }

    $Script:WtExternalToolLaunching = $true
    $Record = $null
    try
    {
        $Record = [ordered]@{
            schema       = 'windows-tweaker.activation-operation/1'
            method       = [string]$Resolved.Id
            switches     = (@($Plan.Switches) -join ' ')
            commit       = [string]$State.Pin.Commit
            elevated     = [bool]$Plan.Elevated
            rootPid      = 0
            rootStartUtc = ''
            launchedUtc  = [datetime]::UtcNow.ToString('o')
            completion   = 'running'
            exitCode     = $null
            observedPids = @()
        }

        Write-WtLog -Level Information -Message ("Starting {0} for {1} tag {2} commit {3} (elevated handoff: {4})" -f $Resolved.Id, $Spec.Name, [string]$State.Pin.Tag, [string]$State.Pin.Commit, [bool]$Plan.Elevated) `
            -Operation 'ExternalTool' -Status 'pending' -NoConsole -Data @{ tool = $Spec.Id; method = [string]$Resolved.Id; commit = [string]$State.Pin.Commit; elevated = [bool]$Plan.Elevated }

        $Run = Invoke-WtExternalToolProcess -FilePath $Plan.FilePath -ArgumentList $Plan.ArgumentList -WorkingDirectory $Plan.WorkingDirectory -Elevate ([bool]$Plan.Elevated)

        $Result.Started = [bool]$Run.Started
        $Result.RootProcessId = [int]$Run.ProcessId

        if ($Run.Cancelled)
        {
            $Result.Status = 'cancelled'
            $Result.Code = 'UacCancelled'
            $Result.Reason = $Run.Reason
            Clear-WtWindowsActivationRecord
            Write-WtLog -Level Warning -Message ("The {0} activation was cancelled at the elevation prompt" -f $Resolved.Id) -Operation 'ExternalTool' -Status 'failed' -NoConsole -Data @{ tool = $Spec.Id; method = [string]$Resolved.Id }
            return $Result
        }

        if (-not $Run.Started)
        {
            $Result.Status = 'failed'
            $Result.Code = 'LaunchFailed'
            $Result.Reason = if ($Run.Reason) { $Run.Reason } else { 'The process could not be started.' }
            Clear-WtWindowsActivationRecord
            Write-WtLog -Level Error -Message ("Starting {0} failed: {1}" -f $Resolved.Id, $Result.Reason) -Operation 'ExternalTool' -Status 'failed' -NoConsole -Data @{ tool = $Spec.Id; method = [string]$Resolved.Id }
            return $Result
        }

        # The record is written before the wait so that a TUI that is closed mid-operation (or a new
        # session) can still see that this may be running, and refuse a duplicate.
        $RootStart = $null
        if ($Run.Process)
        {
            try { $RootStart = $Run.Process.StartTime.ToUniversalTime() } catch { $RootStart = $null }
        }
        if (-not $RootStart) { $RootStart = [datetime]::UtcNow }

        $Record.rootPid = [int]$Run.ProcessId
        $Record.rootStartUtc = ([datetime]$RootStart).ToString('o')
        Write-WtWindowsActivationRecord -Record $Record

        $Wait = Wait-WtWindowsActivationCompletion -RootProcessId ([int]$Run.ProcessId) -RootStartUtc $RootStart -Process $Run.Process -TimeoutSeconds $TimeoutSeconds -TableSource $TableSource

        $Result.ExitCode = $Wait.ExitCode
        $Result.Completion = [string]$Wait.Completion
        $Result.CompletionDetermined = ([string]$Wait.Completion -eq 'Completed')
        $Result.Remaining = [int]$Wait.Remaining

        $Record.completion = ([string]$Wait.Completion).ToLowerInvariant()
        $Record.exitCode = $Wait.ExitCode
        # Only kept while the outcome is unresolved: the ids are what lets a later check still see a
        # detached descendant whose parent already left the process table.
        if (-not $Result.CompletionDetermined)
        {
            $Record.observedPids = @($Wait.Members)
        }
        Write-WtWindowsActivationRecord -Record $Record

        if ($Result.CompletionDetermined)
        {
            # The operation is over. Whether Windows is activated is a question for the licensing
            # record, which the caller re-reads - the exit code is recorded, never believed.
            Clear-WtWindowsActivationRecord
            $Result.Status = 'succeeded'
            $Result.Code = 'Completed'
            Write-WtLog -Level Information -Message ("{0} activation ended (exit code {1})" -f $Resolved.Id, $(if ($null -eq $Wait.ExitCode) { 'unknown' } else { $Wait.ExitCode })) `
                -Operation 'ExternalTool' -Status 'succeeded' -NoConsole -Data @{ tool = $Spec.Id; method = [string]$Resolved.Id; exitCode = $Wait.ExitCode; completion = [string]$Wait.Completion }
            return $Result
        }

        # Not observed to its end: say exactly that. The record stays so the operation is not
        # duplicated while it may still be running.
        $Result.Status = 'unknown'
        $Result.Code = $(if ([string]$Wait.Completion -eq 'Timeout') { 'Timeout' } else { 'CompletionUnknown' })
        $Result.Reason = if ($Wait.Reason) { $Wait.Reason } else { 'The operation was started but its completion could not be determined.' }
        Write-WtLog -Level Warning -Message ("{0} activation completion could not be determined: {1}" -f $Resolved.Id, $Result.Reason) `
            -Operation 'ExternalTool' -Status 'pending' -NoConsole -Data @{ tool = $Spec.Id; method = [string]$Resolved.Id; completion = [string]$Wait.Completion; remaining = [int]$Wait.Remaining }
        return $Result
    }
    finally
    {
        $Script:WtExternalToolLaunching = $false
    }
}

<#
.SYNOPSIS
    Opens the upstream documentation in the default browser.
.DESCRIPTION
    A separate function because the interface layer must not start processes itself: the
    documentation URL is part of the pin, and only a URL from the pin is ever opened.
.OUTPUTS
    An ordered dictionary: Status, Reason.
#>
function Open-WtExternalToolDocumentation
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][object]$Spec)

    if (-not $Spec) { $Spec = Get-WtExternalToolSpec }

    $Result = [ordered]@{ Status = 'succeeded'; Reason = '' }

    try
    {
        $Uri = Assert-WtExternalToolDocumentationUrl -Url ([string]$Spec.DocumentationUrl)
    }
    catch
    {
        $Result.Status = 'failed'
        $Result.Reason = $_.Exception.Message
        return $Result
    }

    if (-not (Test-WtIsWindows))
    {
        $Result.Status = 'unsupported'
        $Result.Reason = 'Opening a browser is only supported on Windows by this tool.'
        return $Result
    }

    try
    {
        $null = Start-Process -FilePath $Uri.AbsoluteUri -ErrorAction Stop
        Write-WtLog -Level Information -Message ("Opened documentation $($Uri.AbsoluteUri)") -Operation 'ExternalTool' -Status 'succeeded' -NoConsole -Data @{ tool = $Spec.Id }
    }
    catch
    {
        $Result.Status = 'failed'
        $Result.Reason = $_.Exception.Message
        Write-WtLog -Level Warning -Message ("Could not open $($Uri.AbsoluteUri): $($_.Exception.Message)") -Operation 'ExternalTool' -Status 'failed' -NoConsole
    }

    return $Result
}

#endregion Launch