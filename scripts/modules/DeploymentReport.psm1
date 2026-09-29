Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ErrorHandling.psm1')

function New-DeploymentStats {
    <# Mutable counters shared by the phases; also the source of action outputs. #>
    [CmdletBinding()]
    param([string]$WarehouseName = '')
    return [pscustomobject]@{
        WarehouseName       = $WarehouseName
        WarehouseId         = ''
        SchemasCreated      = 0
        SchemasExisting     = 0
        TablesCreated       = 0
        TablesExisting      = 0
        ColumnsAdded        = 0
        ViewsDeployed       = 0
        ViewPasses          = 0
        FunctionsProcessed  = 0
        ProceduresProcessed = 0
        UnclassifiedFiles   = 0
        Status              = 'FAILED'
        FailureCategory     = ''
    }
}

function Get-ActionOutputMap {
    <# Ordered name -> value map of every published output (pure; unit tested). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Stats)
    return [ordered]@{
        'warehouse-id'       = $Stats.WarehouseId
        'warehouse-name'     = $Stats.WarehouseName
        'tables-created'     = $Stats.TablesCreated
        'tables-existing'    = $Stats.TablesExisting
        'columns-added'      = $Stats.ColumnsAdded
        'views-deployed'     = $Stats.ViewsDeployed
        'view-passes'        = $Stats.ViewPasses
        'unclassified-files' = $Stats.UnclassifiedFiles
        'deployment-status'  = $Stats.Status
        'failure-category'   = $Stats.FailureCategory
    }
}

function Publish-ActionOutputs {
    <#
      Writes outputs to $GITHUB_OUTPUT (the supported mechanism; ::set-output is
      deprecated). Values are single-line; newlines are stripped defensively so a
      value can never start a second key.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Stats,
        [string]$OutputFile = $env:GITHUB_OUTPUT
    )
    if (-not $OutputFile) {
        Write-DeployLog -Level Debug 'GITHUB_OUTPUT not set; skipping action outputs.'
        return
    }
    $lines = foreach ($kv in (Get-ActionOutputMap -Stats $Stats).GetEnumerator()) {
        $value = ([string]$kv.Value) -replace '[\r\n]', ' '
        "$($kv.Key)=$value"
    }
    Add-Content -LiteralPath $OutputFile -Value $lines -Encoding utf8
}

function Write-UnclassifiedReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files,
        [bool]$AsError = $false
    )
    if ($Files.Count -eq 0) { return }
    Write-DeployBanner -Title 'UNCLASSIFIED SQL (not executed)'
    foreach ($f in $Files) {
        Write-DeployLog "  $($f.RelativePath)"
        Write-DeployLog "    $($f.Reason)"
        $level = if ($AsError) { 'Error' } else { 'Warning' }
        Write-DeployLog -Level $level -File $f.RelativePath -Message "UNCLASSIFIED_SQL: $($f.Reason) File was not executed."
    }
}

function Write-DeploymentSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Stats)

    $row = { param($label, $value) Write-DeployLog ('  {0,-20}{1,4}' -f "${label}:", $value) }

    Write-DeployBanner -Title 'FABRIC WAREHOUSE DEPLOYMENT SUMMARY'
    Write-DeployLog ''
    Write-DeployLog 'Warehouse:'
    Write-DeployLog $Stats.WarehouseName
    Write-DeployLog ''
    Write-DeployLog 'Schemas:'
    & $row 'Created' $Stats.SchemasCreated
    & $row 'Already existing' $Stats.SchemasExisting
    Write-DeployLog ''
    Write-DeployLog 'Tables:'
    & $row 'Created' $Stats.TablesCreated
    & $row 'Already existing' $Stats.TablesExisting
    & $row 'Columns added' $Stats.ColumnsAdded
    Write-DeployLog ''
    Write-DeployLog 'Views:'
    & $row 'Deployed' $Stats.ViewsDeployed
    & $row 'Passes required' $Stats.ViewPasses
    Write-DeployLog ''
    Write-DeployLog 'Functions:'
    & $row 'Processed' $Stats.FunctionsProcessed
    Write-DeployLog ''
    Write-DeployLog 'Stored Procedures:'
    & $row 'Processed' $Stats.ProceduresProcessed
    Write-DeployLog ''
    Write-DeployLog 'Unclassified SQL:'
    & $row 'Files' $Stats.UnclassifiedFiles
    Write-DeployLog ''
    Write-DeployLog 'Result:'
    Write-DeployLog $(if ($Stats.FailureCategory) { "$($Stats.Status) ($($Stats.FailureCategory))" } else { $Stats.Status })
    Write-DeployLog ('=' * 50)
}

Export-ModuleMember -Function New-DeploymentStats, Get-ActionOutputMap, Publish-ActionOutputs, Write-UnclassifiedReport,
    Write-DeploymentSummary
