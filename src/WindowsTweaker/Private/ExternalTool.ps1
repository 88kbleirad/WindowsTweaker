# WindowsTweaker - external tool integration (Microsoft Activation Scripts).
#
# MAS is a third-party activator. WindowsTweaker does not embed, port or modify it: this
# file downloads the upstream file from its official repository at one pinned commit,
# verifies it, and launches it as a separate process when the user asks for that. Nothing
# here runs during navigation, refresh, startup or diagnostics.
#
# Why an external process and not imported code:
#   * MAS is GPL-3.0. Copying its source into this repository would make the combined work
#     subject to the GPL; downloading it at the user's explicit request does not.
#   * The upstream tool is the authority on its own behaviour: it asks the user which
#     activation method to use. WindowsTweaker never preselects a method, never feeds
#     keystrokes and never passes an activation switch.
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
            entryPoint         = 'cmd.exe /c "<file>" (no switches are passed)'
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
    Builds the command line that runs the downloaded script in its own console.
.DESCRIPTION
    The entry point is the documented one: the batch file itself, run through the command
    interpreter with /c. No switch is passed, so the upstream menu keeps every choice: no
    activation method is preselected and no activation command is composed here.

    The path must be the file this feature downloaded, inside its own directory. A path that
    contains a double quote, a percent sign or a line break is refused instead of being
    escaped: cmd.exe expands %NAME% inside double quotes, so such a path could not be passed
    safely.
.OUTPUTS
    An ordered dictionary: Ok, Reason, FilePath, ArgumentList, WorkingDirectory, Elevated,
    CommandLine.
#>
function Get-WtExternalToolLaunchPlan
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][object]$Spec,
        [Parameter(Mandatory = $false)][string]$ToolPath = '',
        [Parameter(Mandatory = $false)][string]$Interpreter = '',
        [Parameter(Mandatory = $false)][AllowNull()][object]$Elevated = $null
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
    }

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
    $Plan.ArgumentList = @('/c', ('"{0}"' -f $Full))
    $Plan.WorkingDirectory = [System.IO.Path]::GetDirectoryName($Full)
    $Plan.CommandLine = '{0} /c "{1}"' -f $Command, $Full
    $Plan.Ok = $true
    return $Plan
}

<#
.SYNOPSIS
    Starts one console process and waits for it, optionally through an explicit UAC handoff.
.DESCRIPTION
    This is the only place a process is started for this feature. It is a separate function
    so tests can replace exactly this seam and observe the plan instead of running it.

    The child gets its own console window (no -NoNewWindow): the upstream interface needs
    one, and its output must never be mixed into the WindowsTweaker screen. -Wait is
    implemented through the returned process object because it is the form that is
    reliable on Windows PowerShell 5.1 for an elevated process.

    Elevation is a handoff, never a silent retry: a refused UAC prompt comes back as
    Cancelled, and nothing is started a second time.
.OUTPUTS
    An ordered dictionary: Started, ExitCode, Cancelled, Reason.
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
        ExitCode  = $null
        Cancelled = $false
        Reason    = ''
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

    if (-not $Process)
    {
        # Without a process object the exit cannot be observed; the launch itself stands.
        $Result.Reason = 'The process was started but its exit could not be observed.'
        return $Result
    }

    try
    {
        $Process.WaitForExit()
        $Result.ExitCode = [int]$Process.ExitCode
    }
    catch
    {
        $Result.Reason = "The process exit could not be read: $($_.Exception.Message)"
    }

    return $Result
}

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
    Launches the verified local copy of the upstream tool.
.DESCRIPTION
    Preconditions, in order: the platform can run it, the local copy is verified against its
    pin, and no launch is already in progress. Then the console-owning caller releases the
    terminal, rehearses the plan, and hands the process off (with an explicit UAC prompt when
    the session is not elevated).

    The return value deliberately separates "the process ran" from "the licensing state
    changed": an exit code is not evidence of activation, so the caller re-reads the licensing
    diagnostics and says whether that read succeeded.
.PARAMETER Elevated
    Whether this session is already elevated. $null means "probe it".
.OUTPUTS
    An ordered dictionary: Status (succeeded, refused, failed, cancelled), Code, Reason,
    Plan, Started, ExitCode.
#>
function Start-WtExternalTool
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param
    (
        [Parameter(Mandatory = $false)][object]$Spec,
        [Parameter(Mandatory = $false)][string]$ToolPath = '',
        [Parameter(Mandatory = $false)][AllowNull()][object]$Elevated = $null,
        [Parameter(Mandatory = $false)][string]$Interpreter = ''
    )

    if (-not $Spec) { $Spec = Get-WtExternalToolSpec }

    $Result = [ordered]@{
        Status   = 'refused'
        Code     = ''
        Reason   = ''
        Plan     = $null
        Started  = $false
        ExitCode = $null
    }

    if (-not (Test-WtExternalToolSupported))
    {
        $Result.Code = 'Unsupported'
        $Result.Reason = 'The upstream tool is a Windows batch script; this platform cannot run it.'
        return $Result
    }

    if ($Script:WtExternalToolLaunching)
    {
        $Result.Code = 'AlreadyLaunched'
        $Result.Reason = 'A launch is already in progress; a second instance is not started.'
        return $Result
    }

    $State = Get-WtExternalToolState -Spec $Spec
    if (-not $State.Ready)
    {
        $Result.Code = $(if ($State.Installed) { 'Integrity' } else { 'NotDownloaded' })
        $Result.Reason = if ($State.Reason) { $State.Reason } else { 'The downloaded file is not present or has not been verified.' }
        return $Result
    }

    $Plan = Get-WtExternalToolLaunchPlan -Spec $Spec -ToolPath $(if ($ToolPath) { $ToolPath } else { $State.Path }) -Interpreter $Interpreter -Elevated $Elevated
    $Result.Plan = $Plan
    if (-not $Plan.Ok)
    {
        $Result.Code = 'LaunchPlan'
        $Result.Reason = $Plan.Reason
        return $Result
    }

    # A dry run is refused here, after the plan exists: the caller can then show exactly what
    # would have been started. Nothing is spawned, elevated or observed.
    if (-not $PSCmdlet.ShouldProcess($Plan.CommandLine, 'launch the external tool'))
    {
        $Result.Status = 'refused'
        $Result.Code = 'DryRun'
        $Result.Reason = 'Dry run: the external tool was not started.'
        return $Result
    }

    $Script:WtExternalToolLaunching = $true
    try
    {
        Write-WtLog -Level Information -Message ("Launching {0} tag {1} commit {2} (elevated handoff: {3})" -f $Spec.Name, [string]$State.Pin.Tag, [string]$State.Pin.Commit, [bool]$Plan.Elevated) `
            -Operation 'ExternalTool' -Status 'pending' -NoConsole -Data @{ tool = $Spec.Id; commit = [string]$State.Pin.Commit; elevated = [bool]$Plan.Elevated }

        $Run = Invoke-WtExternalToolProcess -FilePath $Plan.FilePath -ArgumentList $Plan.ArgumentList -WorkingDirectory $Plan.WorkingDirectory -Elevate ([bool]$Plan.Elevated)

        $Result.Started = [bool]$Run.Started
        $Result.ExitCode = $Run.ExitCode

        if ($Run.Cancelled)
        {
            $Result.Status = 'cancelled'
            $Result.Code = 'UacCancelled'
            $Result.Reason = $Run.Reason
            Write-WtLog -Level Warning -Message ("Launch of {0} was cancelled at the elevation prompt" -f $Spec.Name) -Operation 'ExternalTool' -Status 'failed' -NoConsole -Data @{ tool = $Spec.Id }
            return $Result
        }

        if (-not $Run.Started)
        {
            $Result.Status = 'failed'
            $Result.Code = 'LaunchFailed'
            $Result.Reason = if ($Run.Reason) { $Run.Reason } else { 'The process could not be started.' }
            Write-WtLog -Level Error -Message ("Launch of {0} failed: {1}" -f $Spec.Name, $Result.Reason) -Operation 'ExternalTool' -Status 'failed' -NoConsole -Data @{ tool = $Spec.Id }
            return $Result
        }

        $Result.Status = 'succeeded'
        $Result.Code = 'Started'
        if ($Run.Reason) { $Result.Reason = $Run.Reason }
        Write-WtLog -Level Information -Message ("{0} exited (exit code {1})" -f $Spec.Name, $(if ($null -eq $Run.ExitCode) { 'unknown' } else { $Run.ExitCode })) `
            -Operation 'ExternalTool' -Status 'succeeded' -NoConsole -Data @{ tool = $Spec.Id; exitCode = $Run.ExitCode }
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