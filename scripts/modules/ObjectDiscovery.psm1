Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'SqlParsing.psm1')

<#
  Discovers and classifies the SQL files Fabric Git generates, e.g.

    MyWarehouse.Warehouse/
      dbo/Tables/Customer.sql
      dbo/Views/vw_Customer.sql
      sales/Functions/fn_Tax.sql
      sales/StoredProcedures/usp_Load.sql
      Security/sales.sql            (CREATE SCHEMA)

  Classification is two-factor: the Fabric folder name proposes a type and the
  file content must confirm it with a matching CREATE statement. Anything that
  fails either check is reported as unclassified and is never executed.
  The repository is read-only to this module.
#>

# Deployment order. Within a phase, files are sorted by relative path (invariant culture).
$script:PhaseOrder = @('Schema', 'Table', 'Function', 'View', 'StoredProcedure')

$script:FolderTypeMap = @{
    'tables'            = 'Table'
    'views'             = 'View'
    'functions'         = 'Function'
    'storedprocedures'  = 'StoredProcedure'
    'stored procedures' = 'StoredProcedure'
    'schemas'           = 'Schema'
    'security'          = 'Schema'   # only CREATE SCHEMA files are accepted from here
}

$script:TypeKeyword = @{
    'Table'           = 'TABLE'
    'View'            = 'VIEW'
    'Function'        = 'FUNCTION'
    'StoredProcedure' = 'PROCEDURE'
    'Schema'          = 'SCHEMA'
}

function Get-DeploymentPhaseOrder { return , $script:PhaseOrder }

function Get-SqlObjectClassification {
    <#
    .SYNOPSIS
      Pure classification of one file from its relative path and content.
    .OUTPUTS
      ObjectType ('Schema','Table','Function','View','StoredProcedure','Unclassified'),
      Schema, Name, Reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Sql
    )

    # Tolerate both separators; ignore the file name itself.
    $segments = @($RelativePath -split '[\\/]+' | Where-Object { $_ })
    $folders = if ($segments.Count -gt 1) { $segments[0..($segments.Count - 2)] } else { @() }

    $proposed = $null
    foreach ($f in $folders) {
        $key = $f.ToLowerInvariant()
        if ($script:FolderTypeMap.ContainsKey($key)) { $proposed = $script:FolderTypeMap[$key] }
    }

    $unclassified = {
        param([string]$reason)
        [pscustomobject]@{ ObjectType = 'Unclassified'; Schema = ''; Name = ''; Reason = $reason }
    }

    if (-not $proposed) {
        # Fabric may place CREATE SCHEMA files outside a typed folder; accept those only.
        $schemaStmt = Find-SqlCreateStatement -Sql $Sql -ObjectKeyword 'SCHEMA'
        if ($schemaStmt -and -not (Test-HasOtherCreateStatement -Sql $Sql -Except 'SCHEMA')) {
            return [pscustomobject]@{ ObjectType = 'Schema'; Schema = $schemaStmt.Name; Name = $schemaStmt.Name; Reason = '' }
        }
        return & $unclassified 'Folder does not identify a supported object type.'
    }

    $stmt = Find-SqlCreateStatement -Sql $Sql -ObjectKeyword $script:TypeKeyword[$proposed]
    if (-not $stmt) {
        return & $unclassified "File is in a '$proposed' folder but contains no CREATE $($script:TypeKeyword[$proposed]) statement."
    }
    # Procedure/function bodies may legitimately contain CREATE TABLE #temp etc.,
    # so the single-object check applies only to declarative object files.
    if ($proposed -in @('Table', 'View', 'Schema') -and
        (Test-HasOtherCreateStatement -Sql $Sql -Except $script:TypeKeyword[$proposed])) {
        return & $unclassified 'File contains CREATE statements for more than one object type.'
    }
    return [pscustomobject]@{ ObjectType = $proposed; Schema = $stmt.Schema; Name = $stmt.Name; Reason = '' }
}

function Test-HasOtherCreateStatement {
    <# True when the code (outside comments/strings) creates a different object type. #>
    param([string]$Sql, [string]$Except)
    foreach ($kw in @('TABLE', 'VIEW', 'FUNCTION', 'PROCEDURE', 'SCHEMA')) {
        if ($kw -eq $Except) { continue }
        if (Find-SqlCreateStatement -Sql $Sql -ObjectKeyword $kw) { return $true }
    }
    return $false
}

function Get-WarehouseSqlObjects {
    <#
    .SYNOPSIS
      Recursively discovers *.sql under $WarehouseFolder and classifies each file.
      Returns objects: RelativePath, FullPath, ObjectType, Schema, Name,
      QualifiedName, Sql, Reason.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WarehouseFolder)

    $root = (Resolve-Path -LiteralPath $WarehouseFolder).ProviderPath.TrimEnd('\', '/')
    $files = Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.sql' |
        Where-Object {
            # Skip build output and hidden folders (.git, .vs ...) - they are not Fabric source.
            $rel = $_.FullName.Substring($root.Length + 1)
            -not ($rel -split '[\\/]' | Select-Object -SkipLast 1 | Where-Object { $_ -match '^(\.|bin$|obj$)' })
        } |
        Sort-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/') } -Culture ([cultureinfo]::InvariantCulture)

    foreach ($file in $files) {
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        $sql = [System.IO.File]::ReadAllText($file.FullName)
        $c = Get-SqlObjectClassification -RelativePath $relative -Sql $sql
        [pscustomobject]@{
            RelativePath  = $relative
            FullPath      = $file.FullName
            ObjectType    = $c.ObjectType
            Schema        = $c.Schema
            Name          = $c.Name
            QualifiedName = if ($c.ObjectType -eq 'Unclassified') { $relative } elseif ($c.ObjectType -eq 'Schema') { $c.Name } else { "$($c.Schema).$($c.Name)" }
            Sql           = $sql
            Reason        = $c.Reason
        }
    }
}

Export-ModuleMember -Function Get-DeploymentPhaseOrder, Get-SqlObjectClassification, Get-WarehouseSqlObjects
