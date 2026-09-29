<#
  End-to-end run of scripts/deploy-warehouse.ps1 against the fixture warehouse
  with Fabric/Entra calls mocked and a stateful fake sqlcmd. Verifies phase
  order, multi-pass view resolution, idempotency and table evolution without a
  real Fabric environment.
#>
BeforeDiscovery { $script:skip = $IsWindows }

Describe 'Deployment orchestration (fake sqlcmd)' -Skip:$skip {
    BeforeAll {
        $script:Entry = (Resolve-Path (Join-Path $PSScriptRoot '../../scripts/deploy-warehouse.ps1')).Path
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        foreach ($m in 'ErrorHandling', 'Authentication', 'FabricApi', 'SqlExecution') {
            Import-Module (Join-Path $RepoRoot "scripts/modules/$m.psm1")
        }

        # Fake go-sqlcmd:
        #  - metadata queries answer from $STATE/tables.txt / a fixed schema list
        #  - vw_sales_summary fails until vw_sales_totals_daily has been created
        #  - every executed script's first CREATE line is appended to $STATE/exec.log
        $script:Fake = Join-Path ([System.IO.Path]::GetTempPath()) ("fake-sqlcmd-" + [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $Fake -Value @'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = "-i" ] && FILE="$2"; shift; done
[ -z "$SQLCMDPASSWORD" ] && { echo "Login failed: no password" >&2; exit 1; }
if grep -q "FROM sys.tables" "$FILE"; then cat "$STATE/tables.txt"; exit 0; fi
if grep -q "FROM sys.schemas" "$FILE"; then echo dbo; exit 0; fi
grep -iE -m1 "^(CREATE|ALTER TABLE|ADD )" "$FILE" >> "$STATE/exec.log"
grep -iE "^ADD " "$FILE" >> "$STATE/exec.log"
if [ -n "$BREAK_VIEW" ] && grep -q "CREATE OR ALTER VIEW \[dbo\].\[vw_sales_summary\]" "$FILE"; then
  echo "Msg 208, Level 16, State 1, Line 1" >&2
  echo "Invalid object name 'dbo.vw_finance_monthly'." >&2
  exit 1
fi
if grep -q "CREATE OR ALTER VIEW \[dbo\].\[vw_sales_summary\]" "$FILE" && [ ! -f "$STATE/daily" ]; then
  echo "Msg 208, Level 16, State 1, Line 1" >&2
  echo "Invalid object name 'dbo.vw_sales_totals_daily'." >&2
  exit 1
fi
grep -q "vw_sales_totals_daily\]" "$FILE" && grep -q "CREATE OR ALTER VIEW" "$FILE" && touch "$STATE/daily"
exit 0
'@
        & chmod +x $Fake

        function Invoke-Deploy([string]$TablesTxt, [switch]$BreakView) {
            $state = Join-Path ([System.IO.Path]::GetTempPath()) ("wd-state-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $state | Out-Null
            Set-Content -LiteralPath (Join-Path $state 'tables.txt') -Value $TablesTxt -NoNewline
            New-Item -ItemType File -Path (Join-Path $state 'exec.log') | Out-Null
            $out = New-TemporaryFile
            $vars = @{
                INPUT_WAREHOUSE_NAME   = 'SalesWarehouse'
                INPUT_WAREHOUSE_FOLDER = 'tests/fixtures/SalesWarehouse.Warehouse'
                INPUT_WORKSPACE_ID     = '11111111-1111-1111-1111-111111111111'
                INPUT_TENANT_ID        = '22222222-2222-2222-2222-222222222222'
                INPUT_CLIENT_ID        = '33333333-3333-3333-3333-333333333333'
                INPUT_CLIENT_SECRET    = 'fake-secret'
                GITHUB_WORKSPACE       = $RepoRoot
                GITHUB_OUTPUT          = $out.FullName
                GITHUB_ACTIONS         = 'false'
                RUNNER_TEMP            = $state
                STATE                  = $state
                BREAK_VIEW             = if ($BreakView) { '1' } else { '' }
            }
            $saved = @{}
            foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
            try {
                $global:LASTEXITCODE = 0
                $log = & $Entry 6>&1 | Out-String
                $code = $LASTEXITCODE
                $outputs = @{}
                foreach ($line in (Get-Content -LiteralPath $out.FullName)) { $k, $v = $line -split '=', 2; $outputs[$k] = $v }
                return [pscustomobject]@{
                    ExitCode = $code; Log = $log; Outputs = $outputs
                    Exec = @(Get-Content -LiteralPath (Join-Path $state 'exec.log'))
                    SecretLeft = [bool]$env:SQLCMDPASSWORD
                    TempLeft = @(Get-ChildItem -LiteralPath $state -Directory -Filter 'warehouse-deploy-*').Count
                }
            }
            finally {
                foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
                Remove-Item -LiteralPath $out.FullName -Force
                Remove-Item -LiteralPath $state -Recurse -Force
            }
        }

        $script:AllColumns = @"
dbo|Customer|CustomerId
dbo|Customer|CustomerName
dbo|Customer|Email
sales|Orders|OrderId
sales|Orders|CustomerId
sales|Orders|Amount
sales|Orders|OrderDate
"@
    }

    BeforeEach {
        Mock Get-EntraAccessToken { 'fake-token' }
        Mock Get-FabricWarehouseConnection {
            [pscustomobject]@{ Id = 'wh-123'; Name = 'SalesWarehouse'; SqlEndpoint = 'x.datawarehouse.fabric.microsoft.com' }
        }
        Mock Install-Sqlcmd { $Fake }
    }

    AfterAll { Remove-Item -LiteralPath $Fake -Force -ErrorAction SilentlyContinue }

    It 'scenario 1: fresh warehouse deploys everything in phase order with multi-pass views' {
        $r = Invoke-Deploy -TablesTxt ''
        $r.ExitCode | Should -Be 0 -Because $r.Log
        $r.Outputs['deployment-status'] | Should -Be 'SUCCESS'
        $r.Outputs['warehouse-id'] | Should -Be 'wh-123'
        $r.Outputs['tables-created'] | Should -Be '2'
        $r.Outputs['views-deployed'] | Should -Be '2'
        $r.Outputs['view-passes'] | Should -Be '2'
        $r.Outputs['unclassified-files'] | Should -Be '1'

        # Phase order: schema, tables, function, views, procedure.
        $r.Exec[0] | Should -Match 'CREATE SCHEMA \[sales\]'
        $r.Exec[1] | Should -Match 'CREATE TABLE \[dbo\]\.\[Customer\]'
        $r.Exec[2] | Should -Match 'CREATE TABLE \[sales\]\.\[Orders\]'
        $r.Exec[3] | Should -Match 'CREATE OR ALTER FUNCTION'
        $r.Exec[-1] | Should -Match 'CREATE OR ALTER PROCEDURE'
        $r.Log | Should -Match 'VIEW DEPLOYMENT PASS 2'
        $r.Log | Should -Not -Match 'Something\.sql[\s\S]*CREATE ROLE'   # unclassified never executed
        $r.Exec | Should -Not -Match 'CREATE ROLE'
        $r.SecretLeft | Should -BeFalse
        $r.TempLeft | Should -Be 0
    }

    It 'scenario 2: re-running against an up-to-date warehouse is idempotent' {
        $r = Invoke-Deploy -TablesTxt $AllColumns
        $r.ExitCode | Should -Be 0 -Because $r.Log
        $r.Outputs['tables-created'] | Should -Be '0'
        $r.Outputs['tables-existing'] | Should -Be '2'
        $r.Outputs['columns-added'] | Should -Be '0'
        $r.Exec | Should -Not -Match 'CREATE TABLE'
    }

    It 'scenario 3: a missing nullable column is added with ALTER TABLE ADD' {
        $r = Invoke-Deploy -TablesTxt ($AllColumns -replace "dbo\|Customer\|Email\r?\n", '')
        $r.ExitCode | Should -Be 0 -Because $r.Log
        $r.Outputs['columns-added'] | Should -Be '1'
        $r.Exec | Should -Contain 'ALTER TABLE [dbo].[Customer]'
        $r.Exec | Should -Contain 'ADD [Email] VARCHAR (320) NULL'
        $r.Log | Should -Match '\[ADD COLUMN\] dbo\.Customer\.Email'
    }

    It 'scenario 5: an unresolvable view dependency fails with the real SQL error' {
        $r = Invoke-Deploy -TablesTxt $AllColumns -BreakView
        $r.ExitCode | Should -Be 1
        $r.Outputs['failure-category'] | Should -Be 'VIEW_DEPLOYMENT_FAILED'
        $r.Outputs['views-deployed'] | Should -Be '1'
        $r.Outputs['view-passes'] | Should -Be '2'
        $r.Log | Should -Match 'VIEW DEPLOYMENT FAILED'
        $r.Log | Should -Match "Invalid object name 'dbo.vw_finance_monthly'"
        $r.Log | Should -Match 'UNRESOLVED_DEPENDENCY_OR_INVALID_SQL'
        $r.Exec | Should -Not -Match 'PROCEDURE'   # later phases do not run
    }

    It 'scenario 6: a missing NOT NULL column stops with UNSAFE_SCHEMA_CHANGE before any table DDL' {
        $r = Invoke-Deploy -TablesTxt ($AllColumns -replace "sales\|Orders\|OrderId\r?\n", '' -replace "dbo\|Customer\|Email\r?\n", '')
        $r.ExitCode | Should -Be 1
        $r.Outputs['deployment-status'] | Should -Be 'FAILED'
        $r.Outputs['failure-category'] | Should -Be 'UNSAFE_SCHEMA_CHANGE'
        $r.Log | Should -Match 'OrderId'
        $r.Exec | Should -Not -Match 'ALTER TABLE'   # the safe Email add was NOT applied either
        $r.Log | Should -Match 'FABRIC WAREHOUSE DEPLOYMENT SUMMARY'
    }
}
