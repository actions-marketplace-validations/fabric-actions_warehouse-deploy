Set-StrictMode -Version Latest

<#
  Structured failures and logging.

  A deployment failure is a PSCustomObject (see New-DeploymentFailure) carried
  inside a DeploymentFailureException. Throwing keeps control flow simple; the
  entry script catches it once and prints/publishes the structured details.
#>

$script:ErrorCategories = @(
    'AUTHENTICATION_FAILED'
    'WAREHOUSE_NOT_FOUND'
    'WAREHOUSE_ACCESS_FAILED'
    'SQL_ENDPOINT_DISCOVERY_FAILED'
    'SQLCMD_FAILED'
    'TABLE_PARSE_FAILED'
    'UNSAFE_SCHEMA_CHANGE'
    'VIEW_DEPLOYMENT_FAILED'
    'UNRESOLVED_DEPENDENCY_OR_INVALID_SQL'
    'UNCLASSIFIED_SQL'
    'INVALID_INPUT'
    'UNKNOWN_ERROR'
)

$script:VerboseLogging = $false
# Object paths are relative to the warehouse folder; annotations need repo-relative paths.
$script:AnnotationPathPrefix = ''

class DeploymentFailureException : System.Exception {
    [object]$Failure
    DeploymentFailureException([object]$failure) : base([string]$failure.Message) {
        $this.Failure = $failure
    }
}

function Get-DeploymentErrorCategories {
    return , $script:ErrorCategories
}

function New-DeploymentFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message,
        [string]$Phase = '',
        [string]$ObjectType = '',
        [string]$ObjectName = '',
        [string]$File = '',
        [string]$OriginalError = '',
        [string]$SuggestedAction = ''
    )
    if ($script:ErrorCategories -notcontains $Category) { $Category = 'UNKNOWN_ERROR' }

    return [pscustomobject]@{
        Category        = $Category
        Message         = $Message
        Phase           = $Phase
        ObjectType      = $ObjectType
        ObjectName      = $ObjectName
        File            = $File
        OriginalError   = $OriginalError
        SuggestedAction = $SuggestedAction
    }
}

function Stop-Deployment {
    <# Throws a DeploymentFailureException. Parameters mirror New-DeploymentFailure. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message,
        [string]$Phase = '',
        [string]$ObjectType = '',
        [string]$ObjectName = '',
        [string]$File = '',
        [string]$OriginalError = '',
        [string]$SuggestedAction = ''
    )
    $failure = New-DeploymentFailure @PSBoundParameters
    throw [DeploymentFailureException]::new($failure)
}

function Get-DeploymentFailureFromError {
    <# Normalises any caught ErrorRecord into a failure object. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $ex = $ErrorRecord.Exception
    while ($null -ne $ex) {
        # Match by name, not type identity: a module imported from several nested
        # scopes can yield distinct class instances with the same name.
        if ($ex.GetType().Name -eq 'DeploymentFailureException') { return $ex.Failure }
        $ex = $ex.InnerException
    }
    return New-DeploymentFailure -Category 'UNKNOWN_ERROR' `
        -Message 'Unexpected error in the deployment engine.' `
        -OriginalError ($ErrorRecord.Exception.Message + [Environment]::NewLine + $ErrorRecord.ScriptStackTrace) `
        -SuggestedAction 'Re-run with verbose: true. If it persists, open an issue with the log (secrets are never logged).'
}

function Get-SqlErrorClassification {
    <#
    .SYNOPSIS
      Maps raw sqlcmd output to an error category.
      Kept intentionally coarse in v0.1; the full message is always preserved.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Output = '')

    if ($Output -match '(?i)Login failed|AADSTS\d+|authentication|token.*(expired|invalid)|Cannot open server') {
        return 'AUTHENTICATION_FAILED'
    }
    if ($Output -match '(?i)Invalid object name|Invalid column name|could not be bound|does not exist or you do not have permission|Cannot find the object') {
        return 'UNRESOLVED_DEPENDENCY_OR_INVALID_SQL'
    }
    return 'SQLCMD_FAILED'
}

function Set-DeploymentLogVerbosity {
    param([bool]$Enabled)
    $script:VerboseLogging = $Enabled
}

function Set-AnnotationPathPrefix {
    param([string]$Prefix)
    $p = ($Prefix -replace '\\', '/').Trim()
    $p = ($p -replace '^(\./)+', '').TrimEnd('/')
    $script:AnnotationPathPrefix = $p
}

function Write-DeployLog {
    <#
      Single logging entry point. Uses Write-Host (Information stream) so output is
      not captured as pipeline data. Warning/Error levels also emit GitHub
      workflow commands so they surface as annotations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Message = '',
        [ValidateSet('Info', 'Debug', 'Warning', 'Error')][string]$Level = 'Info',
        [string]$File = ''
    )
    # Text such as SQL error output is not trusted: neutralise anything that
    # looks like a workflow command at the start of a line.
    $Message = $Message -replace '(?m)^(\s*)::', '$1: :'
    if ($File -and $script:AnnotationPathPrefix) { $File = "$script:AnnotationPathPrefix/$File" }
    switch ($Level) {
        'Debug' { if ($script:VerboseLogging) { Write-Host "[debug] $Message" } }
        'Info' { Write-Host $Message }
        'Warning' { Write-Host (Format-WorkflowCommand -Command 'warning' -Message $Message -File $File) }
        'Error' { Write-Host (Format-WorkflowCommand -Command 'error' -Message $Message -File $File) }
    }
}

function Format-WorkflowCommand {
    <# Escapes data per the GitHub workflow-command spec so messages cannot inject commands. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('warning', 'error', 'notice')][string]$Command,
        [AllowEmptyString()][string]$Message = '',
        [string]$File = ''
    )
    $data = $Message.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    if ($File) {
        $f = $File.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A').Replace(':', '%3A').Replace(',', '%2C')
        return "::$Command file=$f::$data"
    }
    return "::$Command::$data"
}

function Write-DeployBanner {
    param([Parameter(Mandatory)][string]$Title)
    $line = '=' * 50
    Write-DeployLog ''
    Write-DeployLog $line
    Write-DeployLog $Title
    Write-DeployLog $line
}

function Write-DeploymentFailure {
    <# Prints a failure in the documented block format. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Failure)

    Write-DeployBanner -Title 'DEPLOYMENT FAILED'
    Write-DeployLog "Category:    $($Failure.Category)"
    if ($Failure.Phase) { Write-DeployLog "Phase:       $($Failure.Phase)" }
    if ($Failure.ObjectType) { Write-DeployLog "Object type: $($Failure.ObjectType)" }
    if ($Failure.ObjectName) { Write-DeployLog "Object:      $($Failure.ObjectName)" }
    if ($Failure.File) { Write-DeployLog "File:        $($Failure.File)" }
    Write-DeployLog ''
    Write-DeployLog 'Reason:'
    Write-DeployLog "  $($Failure.Message)"
    if ($Failure.OriginalError) {
        Write-DeployLog ''
        Write-DeployLog 'Original error:'
        foreach ($l in ($Failure.OriginalError -split "`r?`n")) { if ($l.Trim()) { Write-DeployLog "  $l" } }
    }
    if ($Failure.SuggestedAction) {
        Write-DeployLog ''
        Write-DeployLog 'Suggested action:'
        Write-DeployLog "  $($Failure.SuggestedAction)"
    }
    Write-DeployLog -Level Error -Message "$($Failure.Category): $($Failure.Message)" -File $Failure.File
}

Export-ModuleMember -Function Get-DeploymentErrorCategories, New-DeploymentFailure, Stop-Deployment,
    Get-DeploymentFailureFromError, Get-SqlErrorClassification, Set-DeploymentLogVerbosity, Set-AnnotationPathPrefix, Write-DeployLog,
    Format-WorkflowCommand, Write-DeployBanner, Write-DeploymentFailure
