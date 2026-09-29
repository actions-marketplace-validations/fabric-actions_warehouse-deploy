BeforeAll {
    $modules = Join-Path $PSScriptRoot '../../scripts/modules'
    Import-Module (Join-Path $modules 'ObjectDiscovery.psm1') -Force
    $script:Fixture = Join-Path $PSScriptRoot '../fixtures/SalesWarehouse.Warehouse'
}

Describe 'Get-SqlObjectClassification' {
    It 'classifies <Path> as <Type>' -ForEach @(
        @{ Path = 'dbo/Tables/A.sql'; Sql = 'CREATE TABLE dbo.A (x INT NULL)'; Type = 'Table' }
        @{ Path = 'dbo\Tables\A.sql'; Sql = 'CREATE TABLE dbo.A (x INT NULL)'; Type = 'Table' }
        @{ Path = 'dbo/Views/v.sql'; Sql = 'CREATE VIEW dbo.v AS SELECT 1 AS a'; Type = 'View' }
        @{ Path = 'dbo/Functions/f.sql'; Sql = 'CREATE FUNCTION dbo.f() RETURNS INT AS BEGIN RETURN 1 END'; Type = 'Function' }
        @{ Path = 'dbo/StoredProcedures/p.sql'; Sql = 'CREATE PROCEDURE dbo.p AS SELECT 1'; Type = 'StoredProcedure' }
        @{ Path = 'dbo/Stored Procedures/p.sql'; Sql = 'CREATE PROC dbo.p AS SELECT 1'; Type = 'StoredProcedure' }
        @{ Path = 'Security/sales.sql'; Sql = 'CREATE SCHEMA [sales] AUTHORIZATION [dbo];'; Type = 'Schema' }
        @{ Path = 'Schemas/sales.sql'; Sql = 'CREATE SCHEMA sales'; Type = 'Schema' }
        @{ Path = 'sales.sql'; Sql = 'CREATE SCHEMA sales'; Type = 'Schema' }
        @{ Path = 'dbo/TABLES/A.sql'; Sql = 'create table dbo.A (x int null)'; Type = 'Table' }
    ) {
        (Get-SqlObjectClassification -RelativePath $Path -Sql $Sql).ObjectType | Should -Be $Type
    }

    It 'reports unknown folders as unclassified' {
        $c = Get-SqlObjectClassification -RelativePath 'dbo/Something/NewType.sql' -Sql 'CREATE ROLE x'
        $c.ObjectType | Should -Be 'Unclassified'
        $c.Reason | Should -Match 'Folder'
    }

    It 'rejects a folder/content mismatch' {
        $c = Get-SqlObjectClassification -RelativePath 'dbo/Views/notaview.sql' -Sql 'CREATE TABLE dbo.X (a INT NULL)'
        $c.ObjectType | Should -Be 'Unclassified'
    }

    It 'rejects a view file that also creates a table' {
        $c = Get-SqlObjectClassification -RelativePath 'dbo/Views/v.sql' -Sql "CREATE TABLE dbo.X (a INT NULL)`nGO`nCREATE VIEW dbo.v AS SELECT 1 AS a"
        $c.ObjectType | Should -Be 'Unclassified'
    }

    It 'allows temp-table creation inside a procedure' {
        $c = Get-SqlObjectClassification -RelativePath 'dbo/StoredProcedures/p.sql' -Sql "CREATE PROCEDURE dbo.p AS BEGIN CREATE TABLE #t (a INT NULL); END"
        $c.ObjectType | Should -Be 'StoredProcedure'
    }

    It 'rejects a Security file that is not CREATE SCHEMA' {
        (Get-SqlObjectClassification -RelativePath 'Security/role.sql' -Sql 'CREATE ROLE r').ObjectType | Should -Be 'Unclassified'
    }

    It 'extracts schema and name' {
        $c = Get-SqlObjectClassification -RelativePath 'sales/Views/v.sql' -Sql 'CREATE VIEW [sales].[vw Totals] AS SELECT 1 AS a'
        $c.Schema | Should -Be 'sales'
        $c.Name | Should -Be 'vw Totals'
    }
}

Describe 'Get-WarehouseSqlObjects (fixture)' {
    BeforeAll {
        $script:before = Get-ChildItem -LiteralPath $Fixture -Recurse -File -Force |
            ForEach-Object { "$($_.FullName)|$((Get-FileHash -LiteralPath $_.FullName).Hash)" }
        $script:objects = @(Get-WarehouseSqlObjects -WarehouseFolder $Fixture)
    }

    It 'discovers every .sql file recursively and only .sql files' {
        $objects.Count | Should -Be 8
        $objects.RelativePath | Should -Not -Contain '.platform'
    }

    It 'classifies the fixture correctly' {
        ($objects | Where-Object ObjectType -eq 'Table').QualifiedName | Sort-Object | Should -Be @('dbo.Customer', 'sales.Orders')
        ($objects | Where-Object ObjectType -eq 'View').Count | Should -Be 2
        ($objects | Where-Object ObjectType -eq 'Function').Count | Should -Be 1
        ($objects | Where-Object ObjectType -eq 'StoredProcedure').Count | Should -Be 1
        ($objects | Where-Object ObjectType -eq 'Schema').Name | Should -Be 'sales'
        ($objects | Where-Object ObjectType -eq 'Unclassified').RelativePath | Should -Be 'dbo/Unknown/Something.sql'
    }

    It 'uses forward-slash relative paths and deterministic order' {
        $objects.RelativePath | Should -Not -Match '\\'
        $again = @(Get-WarehouseSqlObjects -WarehouseFolder $Fixture)
        $again.RelativePath | Should -Be $objects.RelativePath
    }

    It 'does not modify any source file' {
        $after = Get-ChildItem -LiteralPath $Fixture -Recurse -File -Force |
            ForEach-Object { "$($_.FullName)|$((Get-FileHash -LiteralPath $_.FullName).Hash)" }
        $after | Should -Be $before
    }

    It 'returns phases in dependency-safe order' {
        $order = Get-DeploymentPhaseOrder
        $order | Should -Be @('Schema', 'Table', 'Function', 'View', 'StoredProcedure')
    }
}
