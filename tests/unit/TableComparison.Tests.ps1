BeforeAll {
    $modules = Join-Path $PSScriptRoot '../../scripts/modules'
    Import-Module (Join-Path $modules 'TableDeployment.psm1') -Force

    $script:CustomerSql = @'
CREATE TABLE [dbo].[Customer]
(
    [CustomerId] INT NOT NULL,
    [CustomerName] VARCHAR(200) NULL,
    [Email] VARCHAR(320) NULL
);
'@
    function New-TableObject([string]$Sql, [string]$Schema = 'dbo', [string]$Name = 'Customer') {
        [pscustomobject]@{
            RelativePath = "$Schema/Tables/$Name.sql"; FullPath = "/src/$Schema/Tables/$Name.sql"
            ObjectType = 'Table'; Schema = $Schema; Name = $Name; QualifiedName = "$Schema.$Name"; Sql = $Sql
        }
    }
    function New-Target([hashtable]$Tables) {
        $d = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::Ordinal)
        foreach ($k in $Tables.Keys) { $d[$k] = [System.Collections.Generic.List[string]]::new([string[]]$Tables[$k]) }
        return $d
    }
}

Describe 'Get-TableChangePlan' {
    It 'existing table with no new columns plans nothing' {
        $src = ConvertFrom-CreateTableSql -Sql $script:CustomerSql
        $p = Get-TableChangePlan -SourceTable $src -TargetColumns @('CustomerId', 'CustomerName', 'Email')
        $p.ColumnsToAdd.Count | Should -Be 0
        $p.UnsafeChanges.Count | Should -Be 0
        $p.ExistingColumns.Count | Should -Be 3
    }

    It 'existing table with one nullable new column produces one ALTER TABLE ADD' {
        $src = ConvertFrom-CreateTableSql -Sql $script:CustomerSql
        $p = Get-TableChangePlan -SourceTable $src -TargetColumns @('CustomerId', 'CustomerName')
        $p.ColumnsToAdd.Count | Should -Be 1
        $p.ColumnsToAdd[0].Column.Name | Should -Be 'Email'
        $p.ColumnsToAdd[0].Statement | Should -Be "ALTER TABLE [dbo].[Customer]`nADD [Email] VARCHAR(320) NULL`n;"
    }

    It 'existing table with multiple nullable new columns adds each' {
        $src = ConvertFrom-CreateTableSql -Sql $script:CustomerSql
        $p = Get-TableChangePlan -SourceTable $src -TargetColumns @('CustomerId')
        $p.ColumnsToAdd.Column.Name | Should -Be @('CustomerName', 'Email')
        $p.UnsafeChanges.Count | Should -Be 0
    }

    It 'new NOT NULL column is reported as unsafe, never added' {
        $src = ConvertFrom-CreateTableSql -Sql 'CREATE TABLE dbo.Customer (CustomerId INT NOT NULL, CustomerType VARCHAR(10) NOT NULL)'
        $p = Get-TableChangePlan -SourceTable $src -TargetColumns @('CustomerId')
        $p.ColumnsToAdd.Count | Should -Be 0
        $p.UnsafeChanges[0].Column | Should -Be 'CustomerType'
        $p.UnsafeChanges[0].Reason | Should -Match 'NOT NULL'
    }

    It 'treats DEFAULT, IDENTITY and unspecified nullability as unsafe' {
        $src = ConvertFrom-CreateTableSql -Sql 'CREATE TABLE dbo.T (Id INT NOT NULL, a INT NULL DEFAULT 0, b BIGINT IDENTITY, c INT)'
        $p = Get-TableChangePlan -SourceTable $src -TargetColumns @('Id')
        $p.UnsafeChanges.Column | Should -Be @('a', 'b', 'c')
    }

    It 'flags a case-only name difference instead of adding a second column' {
        $src = ConvertFrom-CreateTableSql -Sql 'CREATE TABLE dbo.T (Email VARCHAR(10) NULL)'
        $p = Get-TableChangePlan -SourceTable $src -TargetColumns @('email')
        $p.ColumnsToAdd.Count | Should -Be 0
        $p.UnsafeChanges[0].Reason | Should -Match 'case'
    }

    It 'reports target-only columns without dropping them' {
        $src = ConvertFrom-CreateTableSql -Sql 'CREATE TABLE dbo.T (Id INT NULL)'
        $p = Get-TableChangePlan -SourceTable $src -TargetColumns @('Id', 'Legacy')
        $p.TargetOnlyColumns | Should -Be @('Legacy')
        $p.ColumnsToAdd.Count | Should -Be 0
    }

    It 'keeps the terminator off a trailing line comment' {
        $src = ConvertFrom-CreateTableSql -Sql "CREATE TABLE dbo.T (Id INT NULL,`n Email VARCHAR(10) NULL -- contact`n)"
        $p = Get-TableChangePlan -SourceTable $src -TargetColumns @('Id')
        $p.ColumnsToAdd[0].Statement | Should -Match "-- contact`n;$"
    }
}

Describe 'New-TableDeploymentPlan' {
    It 'new table takes the original CREATE TABLE path without parsing' {
        # Unparseable SQL proves the create path never parses the file.
        $obj = New-TableObject -Sql 'CREATE TABLE dbo.Customer AS SELECT 1 AS x'
        $plan = New-TableDeploymentPlan -Tables @($obj) -TargetTables (New-Target @{})
        $plan[0].Action | Should -Be 'Create'
    }

    It 'existing table with nothing new is NoChange' {
        $plan = New-TableDeploymentPlan -Tables @(New-TableObject $script:CustomerSql) `
            -TargetTables (New-Target @{ 'dbo.Customer' = @('CustomerId', 'CustomerName', 'Email') })
        $plan[0].Action | Should -Be 'NoChange'
    }

    It 'existing table with a missing nullable column is Alter' {
        $plan = New-TableDeploymentPlan -Tables @(New-TableObject $script:CustomerSql) `
            -TargetTables (New-Target @{ 'dbo.Customer' = @('CustomerId', 'CustomerName') })
        $plan[0].Action | Should -Be 'Alter'
        $plan[0].Change.ColumnsToAdd.Count | Should -Be 1
    }

    It 'blocks ALL table changes with UNSAFE_SCHEMA_CHANGE when any table is unsafe' {
        $safe = New-TableObject $script:CustomerSql
        $unsafe = New-TableObject -Sql 'CREATE TABLE dbo.Other (Id INT NOT NULL, CustomerType VARCHAR(10) NOT NULL)' -Name 'Other'
        $target = New-Target @{ 'dbo.Customer' = @('CustomerId'); 'dbo.Other' = @('Id') }
        $err = $null
        try { New-TableDeploymentPlan -Tables @($safe, $unsafe) -TargetTables $target } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Failure.Category | Should -Be 'UNSAFE_SCHEMA_CHANGE'
        $err.Exception.Failure.OriginalError | Should -Match 'CustomerType'
        $err.Exception.Failure.Message | Should -Match 'No table changes were made'
    }

    It 'flags a table that differs only by case' {
        $obj = New-TableObject $script:CustomerSql
        { New-TableDeploymentPlan -Tables @($obj) -TargetTables (New-Target @{ 'dbo.customer' = @('CustomerId') }) } |
            Should -Throw -ExpectedMessage '*cannot be deployed automatically*'
    }
}

Describe 'Invoke-TableDeployment (sqlcmd mocked)' {
    BeforeEach {
        $script:stats = [pscustomobject]@{ TablesCreated = 0; TablesExisting = 0; ColumnsAdded = 0 }
        $script:conn = [pscustomobject]@{ Server = 's'; Database = 'd' }
    }

    It 'executes the original file for a new table and ALTER for a missing column' {
        Mock -ModuleName TableDeployment Get-TargetTableColumns { New-Target @{ 'dbo.Customer' = @('CustomerId', 'CustomerName') } }
        Mock -ModuleName TableDeployment Invoke-SqlFile { [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '' } }
        Mock -ModuleName TableDeployment Invoke-SqlText { [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '' } }

        $new = New-TableObject -Sql 'CREATE TABLE dbo.NewT (a INT NULL)' -Name 'NewT'
        Invoke-TableDeployment -Connection $conn -Tables @((New-TableObject $script:CustomerSql), $new) -Stats $stats

        $stats.TablesCreated | Should -Be 1
        $stats.TablesExisting | Should -Be 1
        $stats.ColumnsAdded | Should -Be 1
        Should -Invoke -ModuleName TableDeployment Invoke-SqlFile -Times 1 -Exactly -ParameterFilter { $Path -eq '/src/dbo/Tables/NewT.sql' }
        Should -Invoke -ModuleName TableDeployment Invoke-SqlText -Times 1 -Exactly -ParameterFilter { $Sql -like 'ALTER TABLE `[dbo`].`[Customer`]*ADD `[Email`]*' }
    }

    It 'is idempotent: second run executes nothing' {
        Mock -ModuleName TableDeployment Get-TargetTableColumns { New-Target @{ 'dbo.Customer' = @('CustomerId', 'CustomerName', 'Email') } }
        Mock -ModuleName TableDeployment Invoke-SqlFile { throw 'must not run' }
        Mock -ModuleName TableDeployment Invoke-SqlText { throw 'must not run' }
        Invoke-TableDeployment -Connection $conn -Tables @(New-TableObject $script:CustomerSql) -Stats $stats
        $stats.TablesCreated | Should -Be 0
        $stats.ColumnsAdded | Should -Be 0
    }

    It 'surfaces a failed CREATE TABLE with the SQL error' {
        Mock -ModuleName TableDeployment Get-TargetTableColumns { New-Target @{} }
        Mock -ModuleName TableDeployment Invoke-SqlFile { [pscustomobject]@{ Success = $false; ExitCode = 1; Output = 'Msg 102, Incorrect syntax near x' } }
        $err = $null
        try { Invoke-TableDeployment -Connection $conn -Tables @(New-TableObject $script:CustomerSql) -Stats $stats } catch { $err = $_ }
        $err.Exception.Failure.OriginalError | Should -Match 'Incorrect syntax'
        $err.Exception.Failure.File | Should -Be 'dbo/Tables/Customer.sql'
    }
}
