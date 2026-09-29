Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ErrorHandling.psm1')
Import-Module (Join-Path $PSScriptRoot 'SqlParsing.psm1')
Import-Module (Join-Path $PSScriptRoot 'SqlExecution.psm1')

<#
  CREATE SCHEMA has no "OR ALTER" form, so idempotency comes from checking
  sys.schemas first. Existing schemas are never altered (authorization changes
  are out of scope for v0.1).
#>

function Invoke-SchemaDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Schemas,
        [Parameter(Mandatory)][object]$Stats
    )
    if ($Schemas.Count -eq 0) { return }

    Write-DeployBanner -Title 'SCHEMAS'
    $existing = @(Invoke-SqlQuery -Connection $Connection -Phase 'Schemas' -Sql 'SELECT name FROM sys.schemas;' |
            ForEach-Object { $_[0] })

    foreach ($obj in $Schemas) {
        if ($existing -ccontains $obj.Name) {
            Write-DeployLog "[EXISTS] schema $($obj.Name)"
            $Stats.SchemasExisting++
            continue
        }
        Write-DeployLog "[CREATE SCHEMA] $($obj.Name)"
        $r = Invoke-SqlFile -Connection $Connection -Path $obj.FullPath
        if (-not $r.Success) {
            Stop-Deployment -Category (Get-SqlErrorClassification $r.Output) -Phase 'Schemas' -ObjectType 'Schema' `
                -ObjectName $obj.Name -File $obj.RelativePath `
                -Message "CREATE SCHEMA failed (sqlcmd exit code $($r.ExitCode))." -OriginalError $r.Output
        }
        $Stats.SchemasCreated++
    }
}

Export-ModuleMember -Function Invoke-SchemaDeployment
