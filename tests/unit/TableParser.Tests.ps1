BeforeAll {
    $modules = Join-Path $PSScriptRoot '../../scripts/modules'
    Import-Module (Join-Path $modules 'TableDeployment.psm1') -Force
}

Describe 'ConvertFrom-CreateTableSql' {
    It 'parses a simple CREATE TABLE' {
        $t = ConvertFrom-CreateTableSql -Sql "CREATE TABLE dbo.A`n(`n    Id INT NULL`n);"
        $t.Schema | Should -Be 'dbo'
        $t.Name | Should -Be 'A'
        $t.Columns.Count | Should -Be 1
        $t.Columns[0].Name | Should -Be 'Id'
        $t.Columns[0].DataType | Should -Be 'INT'
        $t.Columns[0].Nullability | Should -Be 'NULL'
    }

    It 'does not split DECIMAL(18,2) on its comma' {
        $sql = @'
CREATE TABLE dbo.Example
(
    Id BIGINT NOT NULL,
    Amount DECIMAL(18,2) NULL,
    Name VARCHAR(200) NULL
);
'@
        $t = ConvertFrom-CreateTableSql -Sql $sql
        $t.Columns.Name | Should -Be @('Id', 'Amount', 'Name')
        $t.Columns[1].DataType | Should -Be 'DECIMAL(18,2)'
        $t.Columns[1].Definition | Should -Be 'DECIMAL(18,2) NULL'
        $t.Columns[0].Nullability | Should -Be 'NOT NULL'
    }

    It 'parses Fabric-generated bracketed layout with spaced type arguments' {
        $sql = Get-Content -Raw (Join-Path $PSScriptRoot '../fixtures/SalesWarehouse.Warehouse/sales/Tables/Orders.sql')
        $t = ConvertFrom-CreateTableSql -Sql $sql
        $t.Schema | Should -Be 'sales'
        $t.Name | Should -Be 'Orders'
        $t.Columns.Name | Should -Be @('OrderId', 'CustomerId', 'Amount', 'OrderDate')
        $t.Columns[2].DataType | Should -Be 'DECIMAL (18, 2)'
    }

    It 'handles VARCHAR and VARCHAR(MAX) definitions' {
        $t = ConvertFrom-CreateTableSql -Sql 'CREATE TABLE [dbo].[T] ([a] VARCHAR(320) NULL, [b] VARCHAR(MAX) NULL, [c] NVARCHAR (50) NOT NULL)'
        $t.Columns.DataType | Should -Be @('VARCHAR(320)', 'VARCHAR(MAX)', 'NVARCHAR (50)')
    }

    It 'unquotes bracketed schema, table and column names including escaped ]]' {
        $t = ConvertFrom-CreateTableSql -Sql 'CREATE TABLE [my schema].[Odd]]Name] ([Col, with comma] INT NULL, [x]]y] INT NULL);'
        $t.Schema | Should -Be 'my schema'
        $t.Name | Should -Be 'Odd]Name'
        $t.Columns.Name | Should -Be @('Col, with comma', 'x]y')
    }

    It 'defaults schema to dbo for single-part names' {
        (ConvertFrom-CreateTableSql -Sql 'create table Customer (Id int null)').Schema | Should -Be 'dbo'
    }

    It 'skips table-level constraints' {
        $sql = @'
CREATE TABLE dbo.C
(
    Id INT NOT NULL,
    Code VARCHAR(10) NULL,
    CONSTRAINT PK_C PRIMARY KEY NONCLUSTERED (Id) NOT ENFORCED,
    PRIMARY KEY (Id),
    UNIQUE (Code),
    FOREIGN KEY (Id) REFERENCES dbo.Other (Id),
    CHECK (Id > 0),
    INDEX IX_C (Code)
);
'@
        $t = ConvertFrom-CreateTableSql -Sql $sql
        $t.Columns.Name | Should -Be @('Id', 'Code')
        $t.Constraints.Count | Should -Be 6
    }

    It 'keeps commas and parentheses inside string defaults and escaped quotes' {
        $sql = "CREATE TABLE dbo.D (Id INT NULL, Note VARCHAR(50) NULL DEFAULT ('a, b (c) it''s'), Z INT NULL)"
        $t = ConvertFrom-CreateTableSql -Sql $sql
        $t.Columns.Name | Should -Be @('Id', 'Note', 'Z')
        $t.Columns[1].HasDefault | Should -BeTrue
        $t.Columns[1].Definition | Should -BeLike "*it''s')"
    }

    It 'ignores commas and keywords inside comments' {
        $sql = @'
CREATE TABLE dbo.E (
    Id INT NOT NULL, -- primary id, NOT NULL
    /* legacy, (removed) column: Old INT NULL, */
    Name VARCHAR(20) NULL -- CONSTRAINT x
);
'@
        $t = ConvertFrom-CreateTableSql -Sql $sql
        $t.Columns.Name | Should -Be @('Id', 'Name')
        $t.Columns[1].Nullability | Should -Be 'NULL'
        $t.Columns[1].HasInlineConstraint | Should -BeFalse
    }

    It 'ignores CREATE TABLE that only appears in a comment' {
        $sql = "-- CREATE TABLE dbo.Fake (x INT NULL)`nCREATE TABLE dbo.Real (y INT NULL)"
        (ConvertFrom-CreateTableSql -Sql $sql).Name | Should -Be 'Real'
    }

    It 'ignores trailing WITH options' {
        $t = ConvertFrom-CreateTableSql -Sql 'CREATE TABLE dbo.W (a INT NULL) WITH (DISTRIBUTION = ROUND_ROBIN);'
        $t.Columns.Count | Should -Be 1
    }

    It 'detects identity, computed and inline constraint columns' {
        $t = ConvertFrom-CreateTableSql -Sql 'CREATE TABLE dbo.F (a BIGINT IDENTITY NOT NULL, b AS (a * 2), c INT NULL UNIQUE, d INT)'
        $t.Columns[0].IsIdentity | Should -BeTrue
        $t.Columns[1].IsComputed | Should -BeTrue
        $t.Columns[2].HasInlineConstraint | Should -BeTrue
        $t.Columns[3].Nullability | Should -Be 'UNSPECIFIED'
    }

    It 'fails with TABLE_PARSE_FAILED when there is no column list' {
        { ConvertFrom-CreateTableSql -Sql 'CREATE TABLE dbo.X AS SELECT 1 AS a' } | Should -Throw -ExpectedMessage '*CREATE TABLE AS SELECT*'
        try { ConvertFrom-CreateTableSql -Sql 'SELECT 1' } catch { $_.Exception.Failure.Category | Should -Be 'TABLE_PARSE_FAILED' }
    }

    It 'fails on unbalanced parentheses' {
        { ConvertFrom-CreateTableSql -Sql 'CREATE TABLE dbo.X (a DECIMAL(18,2 NULL' } | Should -Throw -ExpectedMessage '*unbalanced*'
    }

    It 'fails on duplicate column names' {
        { ConvertFrom-CreateTableSql -Sql 'CREATE TABLE dbo.X (a INT NULL, a INT NULL)' } | Should -Throw -ExpectedMessage '*duplicate*'
    }
}
