<# Drops the [wdit] integration-test objects so every run starts from scratch. #>
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '../../scripts/modules'
Import-Module (Join-Path $modules 'ErrorHandling.psm1')
Import-Module (Join-Path $modules 'SqlExecution.psm1')

$sqlcmd = Install-Sqlcmd -Version '1.8.0' -DestinationRoot $env:RUNNER_TEMP
$env:SQLCMDPASSWORD = $env:IT_CLIENT_SECRET
try {
    $conn = New-SqlConnectionInfo -SqlcmdPath $sqlcmd -Server $env:IT_SQL_ENDPOINT -Database $env:IT_WAREHOUSE_NAME `
        -ClientId $env:IT_CLIENT_ID -TenantId $env:IT_TENANT_ID -TempDirectory $env:RUNNER_TEMP
    $r = Invoke-SqlFile -Connection $conn -Path (Join-Path $PSScriptRoot 'reset.sql')
    if (-not $r.Success) { Write-Host $r.Output; throw "Reset failed (exit $($r.ExitCode))." }
    Write-Host 'Integration schema [wdit] reset.'
}
finally { Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue }
