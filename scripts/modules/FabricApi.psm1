Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ErrorHandling.psm1')

$script:FabricApiBase = 'https://api.fabric.microsoft.com/v1'

function Invoke-FabricGet {
    <#
      GET against the Fabric REST API. The bearer token is passed via a header
      hashtable and is never written to the log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$FailureCategory,
        [Parameter(Mandatory)][string]$FailureMessage
    )
    Write-DeployLog -Level Debug "GET $Uri"
    try {
        return Invoke-RestMethod -Method Get -Uri $Uri -Headers @{ Authorization = "Bearer $AccessToken" } `
            -MaximumRetryCount 3 -RetryIntervalSec 5
    }
    catch {
        $status = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        $suggest = switch ($status) {
            401 { 'The token was rejected. Check the Service Principal credentials.' }
            403 { 'Grant the Service Principal access to the workspace (Contributor or higher) and enable "Service principals can use Fabric APIs" in the Fabric admin portal.' }
            404 { 'Check that workspace-id is correct and the Service Principal has access to it.' }
            default { 'Check network access to api.fabric.microsoft.com and retry.' }
        }
        Stop-Deployment -Category $FailureCategory -Phase 'Discovery' -Message "$FailureMessage (HTTP $status)" `
            -OriginalError $detail -SuggestedAction $suggest
    }
}

function Get-FabricWarehouses {
    <# Lists all warehouses in a workspace, following continuation pages. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$AccessToken
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $uri = "$script:FabricApiBase/workspaces/$WorkspaceId/warehouses"
    $pages = 0
    while ($uri) {
        $pages++
        if ($pages -gt 100) { throw 'Fabric API pagination did not terminate after 100 pages.' }
        $page = Invoke-FabricGet -Uri $uri -AccessToken $AccessToken -FailureCategory 'WAREHOUSE_ACCESS_FAILED' `
            -FailureMessage "Could not list warehouses in workspace $WorkspaceId."
        if ($page.PSObject.Properties['value'] -and $page.value) { foreach ($w in $page.value) { $items.Add($w) } }
        $uri = if ($page.PSObject.Properties['continuationUri']) { $page.continuationUri } else { $null }
    }
    return , $items.ToArray()
}

function Select-FabricWarehouse {
    <# Pure selection logic (unit tested): exactly one displayName match, else a structured failure. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Warehouses,
        [Parameter(Mandatory)][string]$WarehouseName
    )
    # Fabric display names are case-insensitive unique; compare the same way.
    $found = @($Warehouses | Where-Object { $_.displayName -ieq $WarehouseName })
    if ($found.Count -eq 0) {
        $available = (@($Warehouses | ForEach-Object { $_.displayName }) -join ', ')
        Stop-Deployment -Category 'WAREHOUSE_NOT_FOUND' -Phase 'Discovery' `
            -Message "Warehouse '$WarehouseName' was not found in the workspace." `
            -OriginalError "Warehouses visible to the Service Principal: $(if ($available) { $available } else { '(none)' })" `
            -SuggestedAction 'Check warehouse-name, and that the Service Principal can see the warehouse.'
    }
    if ($found.Count -gt 1) {
        Stop-Deployment -Category 'WAREHOUSE_NOT_FOUND' -Phase 'Discovery' `
            -Message "Warehouse name '$WarehouseName' is ambiguous ($($found.Count) matches)." `
            -OriginalError (($found | ForEach-Object { "$($_.displayName) ($($_.id))" }) -join ', ') `
            -SuggestedAction 'Rename warehouses so display names are unique within the workspace.'
    }
    return $found[0]
}

function Get-FabricWarehouseConnection {
    <#
    .SYNOPSIS
      Resolves a warehouse by display name and returns Id, Name and SQL endpoint.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$WarehouseName,
        [Parameter(Mandatory)][string]$AccessToken
    )
    $all = Get-FabricWarehouses -WorkspaceId $WorkspaceId -AccessToken $AccessToken
    $match = Select-FabricWarehouse -Warehouses $all -WarehouseName $WarehouseName

    $detail = Invoke-FabricGet -Uri "$script:FabricApiBase/workspaces/$WorkspaceId/warehouses/$($match.id)" `
        -AccessToken $AccessToken -FailureCategory 'SQL_ENDPOINT_DISCOVERY_FAILED' `
        -FailureMessage "Could not read details of warehouse '$WarehouseName'."

    $endpoint = Get-WarehouseSqlEndpoint -WarehouseDetail $detail
    if (-not $endpoint) {
        Stop-Deployment -Category 'SQL_ENDPOINT_DISCOVERY_FAILED' -Phase 'Discovery' `
            -Message "Warehouse '$WarehouseName' has no SQL connection string yet." `
            -SuggestedAction 'Wait for warehouse provisioning to complete, then retry.'
    }

    return [pscustomobject]@{
        Id          = [string]$match.id
        Name        = [string]$match.displayName
        SqlEndpoint = $endpoint
    }
}

function Get-WarehouseSqlEndpoint {
    <# Extracts and validates the SQL host from a warehouse detail payload. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$WarehouseDetail)

    $props = if ($WarehouseDetail.PSObject.Properties['properties']) { $WarehouseDetail.properties } else { $null }
    if (-not $props -or -not $props.PSObject.Properties['connectionString']) { return $null }
    $cs = [string]$props.connectionString
    if ([string]::IsNullOrWhiteSpace($cs)) { return $null }

    # The endpoint becomes a sqlcmd argument: accept only a plain host name (optionally
    # with tcp: prefix and ,port) to rule out argument injection via API data.
    $cs = $cs.Trim()
    if ($cs -notmatch '^(tcp:)?[A-Za-z0-9.-]+(,\d{1,5})?$') {
        Stop-Deployment -Category 'SQL_ENDPOINT_DISCOVERY_FAILED' -Phase 'Discovery' `
            -Message 'Warehouse connection string has an unexpected format.' -OriginalError $cs
    }
    return $cs
}

Export-ModuleMember -Function Get-FabricWarehouses, Select-FabricWarehouse, Get-FabricWarehouseConnection, Get-WarehouseSqlEndpoint
