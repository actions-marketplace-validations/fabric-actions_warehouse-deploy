BeforeAll {
    $modules = Join-Path $PSScriptRoot '../../scripts/modules'
    Import-Module (Join-Path $modules 'ViewDeployment.psm1') -Force

    function New-Item2([string]$Name) {
        [pscustomobject]@{ QualifiedName = "dbo.$Name"; RelativePath = "dbo/Views/$Name.sql"; Sql = "CREATE VIEW dbo.$Name AS SELECT 1 AS x" }
    }
    $script:ok = [pscustomobject]@{ Success = $true; Output = '' }
    function Fail([string]$msg = "Invalid object name 'dbo.missing'.") { [pscustomobject]@{ Success = $false; Output = $msg } }
}

Describe 'ConvertTo-CreateOrAlterSql' {
    It 'rewrites CREATE VIEW to CREATE OR ALTER VIEW' {
        ConvertTo-CreateOrAlterSql -Sql "CREATE VIEW [dbo].[vwCustomer]`nAS`nSELECT 1 AS a;" |
            Should -Be "CREATE OR ALTER VIEW [dbo].[vwCustomer]`nAS`nSELECT 1 AS a;"
    }

    It 'is case-insensitive and preserves original spacing/case after CREATE' {
        ConvertTo-CreateOrAlterSql -Sql "create   view dbo.v as select 1 as a" |
            Should -Be 'CREATE OR ALTER   view dbo.v as select 1 as a'
    }

    It 'leaves CREATE OR ALTER VIEW untouched (no double rewrite)' {
        $sql = "CREATE OR ALTER VIEW dbo.v AS SELECT 1 AS a"
        ConvertTo-CreateOrAlterSql -Sql $sql | Should -BeExactly $sql
        ConvertTo-CreateOrAlterSql -Sql "create or  alter view dbo.v as select 1 as a" | Should -Be "create or  alter view dbo.v as select 1 as a"
    }

    It 'ignores CREATE VIEW inside comments and strings' {
        $sql = Get-Content -Raw (Join-Path $PSScriptRoot '../fixtures/SalesWarehouse.Warehouse/dbo/Views/vw_sales_totals_daily.sql')
        $out = ConvertTo-CreateOrAlterSql -Sql $sql
        $out | Should -Match '(?m)^-- CREATE VIEW in a comment must never be rewritten'
        $out | Should -Match '(?m)^CREATE OR ALTER VIEW \[dbo\]\.\[vw_sales_totals_daily\]'

        $s2 = "/* CREATE VIEW dbo.x */`nCREATE VIEW dbo.v AS SELECT 'CREATE VIEW' AS t"
        ConvertTo-CreateOrAlterSql -Sql $s2 | Should -Be "/* CREATE VIEW dbo.x */`nCREATE OR ALTER VIEW dbo.v AS SELECT 'CREATE VIEW' AS t"
    }

    It 'only rewrites the first CREATE VIEW' {
        $out = ConvertTo-CreateOrAlterSql -Sql "CREATE VIEW dbo.a AS SELECT 1 AS x`nGO`nCREATE VIEW dbo.b AS SELECT 1 AS x"
        ([regex]::Matches($out, 'CREATE OR ALTER')).Count | Should -Be 1
    }

    It 'does not match identifiers such as [CREATE VIEW x] or CREATE VIEWS' {
        ConvertTo-CreateOrAlterSql -Sql 'SELECT 1 AS [CREATE VIEW x]' | Should -BeNullOrEmpty
        ConvertTo-CreateOrAlterSql -Sql 'CREATE VIEWS dbo.x' | Should -BeNullOrEmpty
    }

    It 'handles a leading SET/GO batch before the view' {
        $out = ConvertTo-CreateOrAlterSql -Sql "SET ANSI_NULLS ON`nGO`nCREATE VIEW dbo.v AS SELECT 1 AS a"
        $out | Should -Be "SET ANSI_NULLS ON`nGO`nCREATE OR ALTER VIEW dbo.v AS SELECT 1 AS a"
    }

    It 'rewrites procedures (PROC abbreviation) and functions' {
        ConvertTo-CreateOrAlterSql -Sql 'CREATE PROC dbo.p AS SELECT 1' -ObjectKeyword PROCEDURE | Should -Be 'CREATE OR ALTER PROC dbo.p AS SELECT 1'
        ConvertTo-CreateOrAlterSql -Sql 'CREATE FUNCTION dbo.f() RETURNS INT AS BEGIN RETURN 1 END' -ObjectKeyword FUNCTION |
            Should -BeLike 'CREATE OR ALTER FUNCTION dbo.f()*'
    }
}

Describe 'Invoke-MultiPassDeployment' {
    BeforeEach { Mock -ModuleName ErrorHandling Write-Host {} }

    It 'resolves A->C->B dependency chains over multiple passes' {
        $deployed = [System.Collections.Generic.HashSet[string]]::new()
        $deps = @{ 'dbo.vw_A' = 'dbo.vw_C'; 'dbo.vw_C' = 'dbo.vw_B'; 'dbo.vw_B' = $null }
        $exec = {
            param($i)
            $d = $deps[$i.QualifiedName]
            if ($d -and -not $deployed.Contains($d)) { return (Fail "Invalid object name '$d'.") }
            [void]$deployed.Add($i.QualifiedName); $ok
        }
        $r = Invoke-MultiPassDeployment -Items @((New-Item2 'vw_A'), (New-Item2 'vw_B'), (New-Item2 'vw_C')) -Executor $exec
        $r.Success | Should -BeTrue
        $r.Passes | Should -Be 2
        $r.Deployed.QualifiedName | Should -Be @('dbo.vw_B', 'dbo.vw_C', 'dbo.vw_A')
    }

    It 'pass 1: A fails, B succeeds; pass 2: A succeeds' {
        $script:bDone = $false
        $exec = {
            param($i)
            if ($i.QualifiedName -eq 'dbo.B') { $script:bDone = $true; return $ok }
            if ($script:bDone) { return $ok } else { return (Fail) }
        }
        $r = Invoke-MultiPassDeployment -Items @((New-Item2 'A'), (New-Item2 'B')) -Executor $exec
        $r.Success | Should -BeTrue
        $r.Passes | Should -Be 2
        $r.Failed.Count | Should -Be 0
    }

    It 'stops when a pass makes no progress and keeps the real errors' {
        $script:calls = 0
        $exec = { param($i) $script:calls++; Fail "Invalid object name 'dbo.nope_$($i.QualifiedName)'." }
        $r = Invoke-MultiPassDeployment -Items @((New-Item2 'A'), (New-Item2 'B')) -Executor $exec
        $r.Success | Should -BeFalse
        $r.Passes | Should -Be 1
        $script:calls | Should -Be 2
        $r.Failed.Count | Should -Be 2
        $r.Failed[0].Output | Should -Match 'nope_dbo.A'
        $r.Failed[0].Category | Should -Be 'UNRESOLVED_DEPENDENCY_OR_INVALID_SQL'
    }

    It 'stops after partial progress when the remainder cannot progress' {
        $exec = { param($i) if ($i.QualifiedName -eq 'dbo.B') { $ok } else { Fail 'Incorrect syntax near FROM' } }
        $r = Invoke-MultiPassDeployment -Items @((New-Item2 'A'), (New-Item2 'B')) -Executor $exec
        $r.Success | Should -BeFalse
        $r.Passes | Should -Be 2
        $r.Deployed.Count | Should -Be 1
        $r.Failed[0].Item.QualifiedName | Should -Be 'dbo.A'
    }

    It 'never exceeds MaxPasses even while progress is still possible' {
        # A -> B -> C in alphabetical order needs 3 passes; cap at 2.
        $deployed = [System.Collections.Generic.HashSet[string]]::new()
        $deps = @{ 'dbo.A' = 'dbo.B'; 'dbo.B' = 'dbo.C'; 'dbo.C' = $null }
        $exec = {
            param($i)
            $d = $deps[$i.QualifiedName]
            if ($d -and -not $deployed.Contains($d)) { return (Fail) }
            [void]$deployed.Add($i.QualifiedName); $ok
        }
        $r = Invoke-MultiPassDeployment -Items @((New-Item2 'A'), (New-Item2 'B'), (New-Item2 'C')) -Executor $exec -MaxPasses 2
        $r.Success | Should -BeFalse
        $r.Passes | Should -Be 2
        $r.StopReason | Should -Match 'Maximum number of passes'
        $r.Failed.Item.QualifiedName | Should -Be @('dbo.A')
    }

    It 'aborts immediately on authentication errors' {
        $script:calls = 0
        $exec = { param($i) $script:calls++; Fail "Login failed for user '<token-identified principal>'." }
        $r = Invoke-MultiPassDeployment -Items @((New-Item2 'A'), (New-Item2 'B')) -Executor $exec
        $r.Success | Should -BeFalse
        $script:calls | Should -Be 1
        $r.Failed[0].Category | Should -Be 'AUTHENTICATION_FAILED'
    }

    It 'succeeds trivially with no items' {
        $r = Invoke-MultiPassDeployment -Items @() -Executor { throw 'unused' }
        $r.Success | Should -BeTrue
        $r.Passes | Should -Be 0
    }
}

Describe 'Invoke-ProgrammableObjectDeployment (sqlcmd mocked)' {
    BeforeEach {
        Mock -ModuleName ErrorHandling Write-Host {}
        $script:stats = [pscustomobject]@{ ViewsDeployed = 0; ViewPasses = 0; FunctionsProcessed = 0; ProceduresProcessed = 0 }
    }

    It 'executes transformed SQL and never the source file' {
        Mock -ModuleName ViewDeployment Invoke-SqlText { [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '' } }
        $null = Invoke-ProgrammableObjectDeployment -Connection ([pscustomobject]@{}) -Objects @(New-Item2 'v1') -ObjectType View -Stats $stats
        Should -Invoke -ModuleName ViewDeployment Invoke-SqlText -Times 1 -Exactly -ParameterFilter { $Sql -eq 'CREATE OR ALTER VIEW dbo.v1 AS SELECT 1 AS x' }
        $stats.ViewsDeployed | Should -Be 1
        $stats.ViewPasses | Should -Be 1
    }

    It 'throws VIEW_DEPLOYMENT_FAILED with every remaining error and records partial stats' {
        Mock -ModuleName ViewDeployment Invoke-SqlText {
            if ($Sql -like '*good*') { [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '' } }
            else { [pscustomobject]@{ Success = $false; ExitCode = 1; Output = "Msg 208, Level 16, State 1`nInvalid object name 'dbo.vw_finance_monthly'." } }
        }
        $err = $null
        try {
            Invoke-ProgrammableObjectDeployment -Connection ([pscustomobject]@{}) -Objects @((New-Item2 'vw_finance_summary'), (New-Item2 'good')) -ObjectType View -Stats $stats
        }
        catch { $err = $_ }
        $err.Exception.Failure.Category | Should -Be 'VIEW_DEPLOYMENT_FAILED'
        $err.Exception.Failure.OriginalError | Should -Match 'vw_finance_monthly'
        $err.Exception.Failure.OriginalError | Should -Match 'UNRESOLVED_DEPENDENCY_OR_INVALID_SQL'
        $err.Exception.Failure.File | Should -Be 'dbo/Views/vw_finance_summary.sql'
        $stats.ViewsDeployed | Should -Be 1
    }
}
