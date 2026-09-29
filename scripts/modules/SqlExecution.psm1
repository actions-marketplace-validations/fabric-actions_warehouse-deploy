Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ErrorHandling.psm1')

<#
  All sqlcmd interaction goes through Invoke-SqlcmdProcess.

  Authentication: go-sqlcmd's ActiveDirectoryServicePrincipal method, with the
  client secret supplied through the SQLCMDPASSWORD environment variable (set by
  the entry script for the lifetime of the deployment). Neither the secret nor
  an access token ever appears on a command line or in a temporary file.
#>

function Get-SqlcmdAssetName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $ri = [System.Runtime.InteropServices.RuntimeInformation]
    $arch = switch ($ri::OSArchitecture) {
        'X64' { 'amd64' }
        'Arm64' { 'arm64' }
        default { throw "Unsupported CPU architecture for sqlcmd: $_" }
    }
    if ($IsWindows) { return "sqlcmd-windows-$arch.zip" }
    if ($IsLinux) { return "sqlcmd-linux-$arch.tar.bz2" }
    if ($IsMacOS) { return "sqlcmd-darwin-$arch.tar.bz2" }
    throw 'Unsupported operating system for sqlcmd.'
}

function Install-Sqlcmd {
    <#
    .SYNOPSIS
      Downloads a pinned go-sqlcmd release into $DestinationRoot and returns the
      executable path. We never fall back to a sqlcmd already on PATH, because the
      legacy ODBC sqlcmd has different flags and exit-code semantics.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    $installDir = Join-Path $DestinationRoot "go-sqlcmd-$Version"
    $exeName = if ($IsWindows) { 'sqlcmd.exe' } else { 'sqlcmd' }
    $exePath = Join-Path $installDir $exeName

    if (-not (Test-Path -LiteralPath $exePath)) {
        $asset = Get-SqlcmdAssetName
        $url = "https://github.com/microsoft/go-sqlcmd/releases/download/v$Version/$asset"
        $archive = Join-Path $DestinationRoot $asset
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null

        Write-DeployLog "Downloading go-sqlcmd v$Version ($asset)"
        try {
            Invoke-WebRequest -Uri $url -OutFile $archive -MaximumRetryCount 3 -RetryIntervalSec 5 -UseBasicParsing
        }
        catch {
            Stop-Deployment -Category 'SQLCMD_FAILED' -Phase 'Setup' `
                -Message "Could not download go-sqlcmd v$Version." -OriginalError $_.Exception.Message `
                -SuggestedAction 'Check the sqlcmd-version input matches a release at https://github.com/microsoft/go-sqlcmd/releases.'
        }

        if ($asset.EndsWith('.zip')) {
            Expand-Archive -LiteralPath $archive -DestinationPath $installDir -Force
        }
        else {
            & tar -xjf $archive -C $installDir
            if ($LASTEXITCODE -ne 0) {
                Stop-Deployment -Category 'SQLCMD_FAILED' -Phase 'Setup' -Message "Failed to extract $asset (tar exit code $LASTEXITCODE)."
            }
            & chmod +x $exePath
        }
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    }

    $ErrorActionPreference = 'Continue'
    $versionOutput = & $exePath --version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Stop-Deployment -Category 'SQLCMD_FAILED' -Phase 'Setup' -Message 'Installed sqlcmd did not run.' -OriginalError $versionOutput
    }
    Write-DeployLog "sqlcmd: $($versionOutput.Trim())"
    return $exePath
}

function New-SqlConnectionInfo {
    <# Connection description. Deliberately contains no secret. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SqlcmdPath,
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$TempDirectory,
        [int]$LoginTimeoutSeconds = 60
    )
    return [pscustomobject]@{
        SqlcmdPath          = $SqlcmdPath
        Server              = $Server
        Database            = $Database
        ClientId            = $ClientId
        TenantId            = $TenantId
        TempDirectory       = $TempDirectory
        LoginTimeoutSeconds = $LoginTimeoutSeconds
    }
}

function Get-SqlcmdArgumentList {
    <# The only place sqlcmd arguments are built. Pure function (unit tested). #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [string]$InputFile,
        [switch]$QueryOutput
    )
    $argList = @(
        '-S', $Connection.Server
        '-d', $Connection.Database
        '--authentication-method', 'ActiveDirectoryServicePrincipal'
        '-U', "$($Connection.ClientId)@$($Connection.TenantId)"
        '-l', [string]$Connection.LoginTimeoutSeconds
        '-b'            # exit non-zero on SQL error; we still check $LASTEXITCODE ourselves
    )
    if ($QueryOutput) {
        # No headers, trimmed values, pipe separator: machine-readable rows.
        $argList += @('-h', '-1', '-W', '-s', '|')
    }
    if ($InputFile) { $argList += @('-i', $InputFile) }
    return , $argList
}

function Invoke-SqlcmdProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][string]$InputFile,
        [switch]$QueryOutput
    )
    if (-not $env:SQLCMDPASSWORD) {
        Stop-Deployment -Category 'AUTHENTICATION_FAILED' -Phase 'SQL' -Message 'SQLCMDPASSWORD is not set; cannot authenticate sqlcmd.'
    }

    $argList = Get-SqlcmdArgumentList -Connection $Connection -InputFile $InputFile -QueryOutput:$QueryOutput
    Write-DeployLog -Level Debug "sqlcmd -S $($Connection.Server) -d $($Connection.Database) -i $InputFile"

    # 2>&1 so SQL errors (stderr) are captured with the rest of the output. Locally
    # relax error preferences so stderr text never becomes a terminating error:
    # $LASTEXITCODE is the single source of truth for success.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $global:LASTEXITCODE = 0
    $raw = & $Connection.SqlcmdPath @argList 2>&1
    $exitCode = $LASTEXITCODE

    $lines = @($raw | ForEach-Object { "$_" })
    $output = ($lines -join [Environment]::NewLine).Trim()
    return [pscustomobject]@{
        Success  = ($exitCode -eq 0)
        ExitCode = $exitCode
        Output   = $output
        Lines    = $lines
    }
}

function Invoke-SqlFile {
    <# Executes a SQL file as-is. Returns Success/ExitCode/Output. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "SQL file not found: $Path"
    }
    return Invoke-SqlcmdProcess -Connection $Connection -InputFile $Path
}

function Invoke-SqlText {
    <#
      Executes SQL text through a short-lived temp file (avoids command-line quoting
      and length issues). The file holds only SQL - never credentials - and is
      always removed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][string]$Sql,
        [switch]$QueryOutput
    )
    $tempFile = Join-Path $Connection.TempDirectory ("wd-" + [guid]::NewGuid().ToString('N') + '.sql')
    try {
        [System.IO.File]::WriteAllText($tempFile, $Sql, [System.Text.UTF8Encoding]::new($false))
        return Invoke-SqlcmdProcess -Connection $Connection -InputFile $tempFile -QueryOutput:$QueryOutput
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SqlQuery {
    <#
      Runs a metadata query and returns rows as string arrays (split on '|').
      Throws a structured failure if sqlcmd fails: metadata queries are
      prerequisites, so there is nothing sensible to continue with.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][string]$Sql,
        [string]$Phase = 'Metadata'
    )
    $result = Invoke-SqlText -Connection $Connection -Sql ("SET NOCOUNT ON;`n" + $Sql) -QueryOutput
    if (-not $result.Success) {
        Stop-Deployment -Category (Get-SqlErrorClassification $result.Output) -Phase $Phase `
            -Message "Metadata query failed (sqlcmd exit code $($result.ExitCode))." -OriginalError $result.Output
    }
    # Explicit list: pipeline output would unroll a single row into its columns.
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $result.Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $rows.Add([string[]]$line.Trim().Split('|'))
    }
    return , $rows.ToArray()
}

function Invoke-SqlScalar {
    <# Returns the first column of the first row, or $null. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][string]$Sql,
        [string]$Phase = 'Metadata'
    )
    $rows = Invoke-SqlQuery -Connection $Connection -Sql $Sql -Phase $Phase
    if ($rows.Count -eq 0) { return $null }
    return $rows[0][0]
}

Export-ModuleMember -Function Install-Sqlcmd, New-SqlConnectionInfo, Get-SqlcmdArgumentList, Invoke-SqlcmdProcess,
    Invoke-SqlFile, Invoke-SqlText, Invoke-SqlQuery, Invoke-SqlScalar
