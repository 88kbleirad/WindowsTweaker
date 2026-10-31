# WindowsTweaker - process execution, signature validation and verified downloads.
#
# Rules encoded here (from the project security requirements):
#   * never Invoke-Expression, never a download-and-execute pipeline
#   * downloads happen only from an explicitly supplied official https:// URL,
#     only when not in -WhatIf, and the downloaded binary must carry a valid
#     Authenticode signature from the expected publisher before it is executed
#   * native exit codes are checked and partial failures reported

function Invoke-WtProcess
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param
    (
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 900,
        [Parameter(Mandatory = $false)][switch]$CaptureOutput
    )

    $Operation = 'InvokeProcess'
    $Target = $FilePath

    if (-not (Test-Path -LiteralPath $FilePath))
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message "Executable not found: $FilePath"
    }

    # One confirmation per tweak: Invoke-WtTweak/Undo-WtTweak confirm once, and the
    # providers must not prompt again while that apply/rollback is in progress.
    if ((Get-WtOperationContext).SuppressConfirm) { $ConfirmPreference = 'None' }

    if (-not $PSCmdlet.ShouldProcess($Target, "run '$FilePath $($ArgumentList -join ' ')'"))
    {
        return New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation $Operation -Target $Target -Message "Would run $FilePath $($ArgumentList -join ' ')"
    }

    $Process = $null
    $Output = $null

    try
    {
        if ($CaptureOutput)
        {
            $Output = & $FilePath @ArgumentList 2>&1
            $ExitCode = $LASTEXITCODE
            if ($null -eq $ExitCode)
            {
                $ExitCode = 0
            }
        }
        else
        {
            $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $StartInfo.FileName = $FilePath
            $StartInfo.UseShellExecute = $false
            $StartInfo.RedirectStandardOutput = $true
            $StartInfo.RedirectStandardError = $true
            foreach ($Argument in $ArgumentList)
            {
                $StartInfo.ArgumentList.Add($Argument)
            }

            $Process = [System.Diagnostics.Process]::Start($StartInfo)
            if (-not $Process.WaitForExit($TimeoutSeconds * 1000))
            {
                try
                {
                    $Process.Kill()
                }
                catch
                {
                    # The process may have exited between the timeout and the kill.
                    Write-WtLog -Level Debug -Message "Could not terminate process $FilePath after timeout: $($_.Exception.Message)" -Operation $Operation -NoConsole
                }
                $Message = "Process timed out after $TimeoutSeconds seconds: $FilePath"
                Write-WtLog -Level Error -Message $Message -Operation $Operation -Status 'failed'
                return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $Message
            }

            $Output = @($Process.StandardOutput.ReadToEnd(), $Process.StandardError.ReadToEnd()) -join [Environment]::NewLine
            $ExitCode = $Process.ExitCode
        }
    }
    catch
    {
        Write-WtLog -Level Error -Message "Failed to run $FilePath" -Operation $Operation -Status 'failed' -Exception $_.Exception
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $_.Exception.Message -ErrorRecord $_
    }
    finally
    {
        if ($Process)
        {
            $Process.Dispose()
        }
    }

    if ($ExitCode -ne 0)
    {
        $Message = Get-WtString -Key 'Error.ProcessFailed' -Arguments @((Split-Path -Path $FilePath -Leaf), $ExitCode)
        if ($Output)
        {
            $Message = "$Message $([Environment]::NewLine)$(([string]$Output).Trim())"
        }
        Write-WtLog -Level Error -Message $Message -Operation $Operation -Status 'failed'
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $Message
    }

    return New-WtOperationResult -Status 'succeeded' -Operation $Operation -Target $Target -Message "Ran $(Split-Path -Path $FilePath -Leaf) (exit code 0)"
}

<#
.SYNOPSIS
    Reads the Authenticode signature of a file (thin seam for tests).
#>
function Get-WtAuthenticodeSignature
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Path)

    return Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
}

<#
.SYNOPSIS
    Validates that a file is signed by the expected publisher.
.PARAMETER ExpectedPublisher
    Substring that must appear in the signer's subject, e.g. 'Microsoft Corporation'.
#>
function Test-WtFileSignature
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedPublisher
    )

    $Result = [ordered]@{
        PSTypeName = 'WindowsTweaker.SignatureResult'
        Path       = $Path
        Valid      = $false
        Status     = 'Unknown'
        Signer     = $null
        Reason     = ''
    }

    if (-not (Test-Path -LiteralPath $Path))
    {
        $Result.Reason = "File does not exist: $Path"
        return $Result
    }

    if (-not (Get-Command -Name Get-AuthenticodeSignature -ErrorAction Ignore))
    {
        $Result.Reason = 'Get-AuthenticodeSignature is not available; signature cannot be validated.'
        return $Result
    }

    try
    {
        $Signature = Get-WtAuthenticodeSignature -Path $Path
    }
    catch
    {
        $Result.Reason = $_.Exception.Message
        return $Result
    }

    $Result.Status = [string]$Signature.Status
    $Result.Signer = [string]$Signature.SignerCertificate.Subject

    if ($Signature.Status -ne 'Valid')
    {
        $Result.Reason = Get-WtString -Key 'Error.SignatureInvalid' -Arguments @((Split-Path -Path $Path -Leaf))
        return $Result
    }

    if ($ExpectedPublisher -and ($Result.Signer -notlike "*$ExpectedPublisher*"))
    {
        $Result.Reason = "Signer '$($Result.Signer)' does not match expected publisher '$ExpectedPublisher'."
        return $Result
    }

    $Result.Valid = $true
    return $Result
}

<#
.SYNOPSIS
    Downloads a file from an official https:// URL and validates its signature.
.DESCRIPTION
    Refuses http://, refuses to run anything, and does not download at all in -WhatIf.
    Returns the local path on success so the caller can decide whether to execute it.
#>
function Get-WtVerifiedDownload
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param
    (
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$ExpectedPublisher,
        [Parameter(Mandatory = $false)][string]$DestinationPath
    )

    $Operation = 'Download'

    if ($Uri -notmatch '^https://')
    {
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Uri -Message "Only https:// downloads are allowed: $Uri"
    }

    if (-not $DestinationPath)
    {
        $DestinationPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetFileName(([uri]$Uri).AbsolutePath))
    }

    # One confirmation per tweak: Invoke-WtTweak/Undo-WtTweak confirm once, and the
    # providers must not prompt again while that apply/rollback is in progress.
    if ((Get-WtOperationContext).SuppressConfirm) { $ConfirmPreference = 'None' }

    if (-not $PSCmdlet.ShouldProcess($Uri, "download to '$DestinationPath'")) 
    {
        return New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation $Operation -Target $Uri -Message "Would download $Uri to $DestinationPath"
    }

    try
    {
        Invoke-WebRequest -Uri $Uri -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop
    }
    catch
    {
        Write-WtLog -Level Error -Message (Get-WtString -Key 'Error.DownloadFailed' -Arguments @($Uri)) -Operation $Operation -Status 'failed' -Exception $_.Exception
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Uri -Message $_.Exception.Message -ErrorRecord $_
    }

    $Signature = Test-WtFileSignature -Path $DestinationPath -ExpectedPublisher $ExpectedPublisher
    if (-not $Signature.Valid)
    {
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction Ignore
        Write-WtLog -Level Error -Message $Signature.Reason -Operation $Operation -Status 'failed'
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Uri -Message $Signature.Reason
    }

    return New-WtOperationResult -Status 'succeeded' -Operation $Operation -Target $Uri -Message "Downloaded and verified $(Split-Path -Path $DestinationPath -Leaf) (signer: $($Signature.Signer))"
}
