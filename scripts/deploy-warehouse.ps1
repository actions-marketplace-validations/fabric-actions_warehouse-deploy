#Requires -Version 7.2
<#
.SYNOPSIS
  Entry point for fabric-actions/warehouse-deploy.

.DESCRIPTION
  Reads its configuration from INPUT_* environment variables (set by action.yml),
  never from interpolated command text, so input values cannot inject code.

  Phases: validate -> discover files -> authenticate -> resolve warehouse ->
  install sqlcmd -> schemas -> tables -> functions -> views -> procedures.

  Exit code: 0 on success, 1 on any failure.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modules = Join-Path $PSScriptRoot 'modules'
foreach ($m in 'ErrorHandling', 'SqlParsing', 'SqlExecution', 'Authentication', 'FabricApi',
    'ObjectDiscovery', 'SchemaDeployment', 'TableDeployment', 'ViewDeployment', 'DeploymentReport') {
    Import-Module (Join-Path $modules "$m.psm1")
}

$GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

function Get-Input {
    param([string]$Name, [switch]$Required, [string]$Default = '')
    $value = [Environment]::GetEnvironmentVariable("INPUT_$Name")
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Required) {
            Stop-Deployment -Category 'INVALID_INPUT' -Phase 'Validation' -Message "Input '$($Name.ToLower().Replace('_','-'))' is required."
        }
        return $Default
    }
    return $value.Trim()
}

function ConvertTo-Bool {
    param([string]$Name, [string]$Value)
    switch -Regex ($Value) {
        '^(?i)(true|yes|1)$' { return $true }
        '^(?i)(false|no|0|)$' { return $false }
        default { Stop-Deployment -Category 'INVALID_INPUT' -Phase 'Validation' -Message "Input '$Name' must be true or false (got '$Value')." }
    }
}

function Resolve-WarehouseFolder {
    <# Resolves the folder relative to the workspace and refuses paths that escape it. #>
    param([string]$Folder)
    $workspace = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).ProviderPath }
    $workspace = [System.IO.Path]::GetFullPath($workspace)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $workspace $Folder))

    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $prefix = $workspace.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not ($candidate.Equals($workspace, $comparison) -or $candidate.StartsWith($prefix, $comparison))) {
        Stop-Deployment -Category 'INVALID_INPUT' -Phase 'Validation' `
            -Message "warehouse-folder must be inside the repository workspace (got '$Folder')."
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        Stop-Deployment -Category 'INVALID_INPUT' -Phase 'Validation' `
            -Message "warehouse-folder '$Folder' does not exist." `
            -SuggestedAction 'Run actions/checkout first and point warehouse-folder at the Fabric-generated <Name>.Warehouse folder.'
    }
    return $candidate
}

$stats = New-DeploymentStats
$exitCode = 1
$tempDir = $null

try {
    # ---------------------------------------------------------------- validate
    $warehouseName = Get-Input 'WAREHOUSE_NAME' -Required
    $warehouseFolder = Get-Input 'WAREHOUSE_FOLDER' -Required
    $workspaceId = Get-Input 'WORKSPACE_ID' -Required
    $tenantId = Get-Input 'TENANT_ID' -Required
    $clientId = Get-Input 'CLIENT_ID' -Required
    $clientSecret = [Environment]::GetEnvironmentVariable('INPUT_CLIENT_SECRET')
    if ([string]::IsNullOrEmpty($clientSecret)) {
        Stop-Deployment -Category 'INVALID_INPUT' -Phase 'Validation' -Message "Input 'client-secret' is required."
    }
    # Belt and braces: GitHub masks secrets already, but the value may come from a non-secret source.
    Add-SecretMask $clientSecret

    $failOnUnclassified = ConvertTo-Bool 'fail-on-unclassified-sql' (Get-Input 'FAIL_ON_UNCLASSIFIED_SQL' -Default 'false')
    $verbose = ConvertTo-Bool 'verbose' (Get-Input 'VERBOSE' -Default 'false')
    $sqlcmdVersion = Get-Input 'SQLCMD_VERSION' -Default '1.8.0'
    $maxPassesText = Get-Input 'MAX_VIEW_PASSES' -Default '0'

    Set-DeploymentLogVerbosity -Enabled $verbose
    $stats.WarehouseName = $warehouseName

    foreach ($pair in @(@('workspace-id', $workspaceId), @('tenant-id', $tenantId), @('client-id', $clientId))) {
        if ($pair[1] -notmatch $GuidPattern) {
            Stop-Deployment -Category 'INVALID_INPUT' -Phase 'Validation' -Message "Input '$($pair[0])' must be a GUID."
        }
    }
    if ($sqlcmdVersion -notmatch '^\d+\.\d+\.\d+$') {
        Stop-Deployment -Category 'INVALID_INPUT' -Phase 'Validation' -Message "Input 'sqlcmd-version' must look like 1.8.0 (got '$sqlcmdVersion')."
    }
    $maxPasses = 0
    if (-not [int]::TryParse($maxPassesText, [ref]$maxPasses) -or $maxPasses -lt 0 -or $maxPasses -gt 1000) {
        Stop-Deployment -Category 'INVALID_INPUT' -Phase 'Validation' -Message "Input 'max-view-passes' must be an integer 0-1000 (0 = automatic)."
    }
    if ($warehouseName.Length -gt 256 -or $warehouseName -match '[\x00-\x1F]') {
        Stop-Deployment -Category 'INVALID_INPUT' -Phase 'Validation' -Message "Input 'warehouse-name' is not a valid display name."
    }
    $folderPath = Resolve-WarehouseFolder -Folder $warehouseFolder
    Set-AnnotationPathPrefix -Prefix $warehouseFolder

    # ---------------------------------------------------------------- discover
    Write-DeployBanner -Title 'FABRIC WAREHOUSE DEPLOY'
    Write-DeployLog "Warehouse folder: $warehouseFolder"

    $objects = @(Get-WarehouseSqlObjects -WarehouseFolder $folderPath)
    $byType = @{}
    foreach ($t in (Get-DeploymentPhaseOrder) + 'Unclassified') {
        $byType[$t] = @($objects | Where-Object ObjectType -eq $t)
    }
    Write-DeployLog ("Discovered {0} SQL file(s): {1} schema, {2} table, {3} function, {4} view, {5} procedure, {6} unclassified" -f
        $objects.Count, $byType.Schema.Count, $byType.Table.Count, $byType.Function.Count, $byType.View.Count,
        $byType.StoredProcedure.Count, $byType.Unclassified.Count)

    $stats.UnclassifiedFiles = $byType.Unclassified.Count
    Write-UnclassifiedReport -Files $byType.Unclassified -AsError $failOnUnclassified
    if ($failOnUnclassified -and $byType.Unclassified.Count -gt 0) {
        Stop-Deployment -Category 'UNCLASSIFIED_SQL' -Phase 'Discovery' `
            -Message "$($byType.Unclassified.Count) SQL file(s) could not be classified and fail-on-unclassified-sql is true." `
            -OriginalError (($byType.Unclassified | ForEach-Object { $_.RelativePath }) -join "`n") `
            -SuggestedAction 'Deploy these objects manually, or set fail-on-unclassified-sql: false to warn only.'
    }

    # ---------------------------------------------------------------- authenticate + resolve
    $fabricToken = Get-EntraAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret -Scope (Get-FabricScope)
    # Fail fast with AUTHENTICATION_FAILED if the principal cannot get a SQL token at all.
    $null = Get-EntraAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret -Scope (Get-SqlScope)

    $warehouse = Get-FabricWarehouseConnection -WorkspaceId $workspaceId -WarehouseName $warehouseName -AccessToken $fabricToken
    $fabricToken = $null
    $stats.WarehouseId = $warehouse.Id
    $stats.WarehouseName = $warehouse.Name
    Write-DeployLog "Warehouse: $($warehouse.Name)"
    Write-DeployLog "Warehouse ID: $($warehouse.Id)"
    Write-DeployLog -Level Debug "SQL endpoint: $($warehouse.SqlEndpoint)"

    # ---------------------------------------------------------------- sqlcmd
    $tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    $tempDir = Join-Path $tempRoot ('warehouse-deploy-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $sqlcmdPath = Install-Sqlcmd -Version $sqlcmdVersion -DestinationRoot $tempRoot

    $env:SQLCMDPASSWORD = $clientSecret
    $connection = New-SqlConnectionInfo -SqlcmdPath $sqlcmdPath -Server $warehouse.SqlEndpoint -Database $warehouse.Name `
        -ClientId $clientId -TenantId $tenantId -TempDirectory $tempDir

    $probe = Invoke-SqlText -Connection $connection -Sql 'SELECT 1;'
    if (-not $probe.Success) {
        Stop-Deployment -Category (Get-SqlErrorClassification $probe.Output) -Phase 'Connect' `
            -Message "Could not connect to the warehouse SQL endpoint (sqlcmd exit code $($probe.ExitCode))." `
            -OriginalError $probe.Output `
            -SuggestedAction 'Ensure the Service Principal has at least Contributor on the workspace and that the tenant allows service principals to use Fabric.'
    }

    # ---------------------------------------------------------------- deploy
    Invoke-SchemaDeployment -Connection $connection -Schemas $byType.Schema -Stats $stats

    if ($byType.Table.Count -gt 0) { Write-DeployBanner -Title 'TABLES' }
    Invoke-TableDeployment -Connection $connection -Tables $byType.Table -Stats $stats

    foreach ($type in 'Function', 'View', 'StoredProcedure') {
        if ($byType[$type].Count -eq 0) { continue }
        $passes = if ($type -eq 'View') { $maxPasses } else { 0 }
        $null = Invoke-ProgrammableObjectDeployment -Connection $connection -Objects $byType[$type] `
            -ObjectType $type -Stats $stats -MaxPasses $passes
    }

    $stats.Status = 'SUCCESS'
    $exitCode = 0
}
catch {
    $failure = Get-DeploymentFailureFromError -ErrorRecord $_
    $stats.Status = 'FAILED'
    $stats.FailureCategory = $failure.Category
    Write-DeploymentFailure -Failure $failure
}
finally {
    # Remove the credential from the process environment and delete temp SQL.
    Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue
    if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-DeploymentSummary -Stats $stats
    Publish-ActionOutputs -Stats $stats
}

exit $exitCode
