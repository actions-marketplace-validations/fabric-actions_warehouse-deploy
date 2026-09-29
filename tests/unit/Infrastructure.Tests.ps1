BeforeAll {
    $modules = Join-Path $PSScriptRoot '../../scripts/modules'
    foreach ($m in 'ErrorHandling', 'SqlParsing', 'SqlExecution', 'FabricApi', 'DeploymentReport') {
        Import-Module (Join-Path $modules "$m.psm1") -Force
    }
}

Describe 'Get-SqlCodeMask' {
    It 'preserves length and newlines' {
        $sql = "SELECT 'a--b' -- c`n/* x /* nested */ y */ [q]"
        $mask = Get-SqlCodeMask -Sql $sql
        $mask.Length | Should -Be $sql.Length
        $mask.IndexOf("`n") | Should -Be $sql.IndexOf("`n")
        $mask | Should -Not -Match 'nested'
        $mask | Should -Not -Match 'a--b'
    }
    It 'handles escaped quotes in strings' {
        (Get-SqlCodeMask -Sql "'it''s, (x)' , y") | Should -Match '^\x27\s+\x27 , y$'
    }
}

Describe 'Split-SqlTopLevel' {
    It 'splits only on top-level commas' {
        $parts = Split-SqlTopLevel -Sql "a DECIMAL(18,2), b VARCHAR(10) DEFAULT ('x,y'), [c,d] INT"
        $parts | Should -Be @('a DECIMAL(18,2)', "b VARCHAR(10) DEFAULT ('x,y')", '[c,d] INT')
    }
}

Describe 'Get-SqlErrorClassification' {
    It 'maps <Text> to <Category>' -ForEach @(
        @{ Text = "Msg 208 Invalid object name 'dbo.x'."; Category = 'UNRESOLVED_DEPENDENCY_OR_INVALID_SQL' }
        @{ Text = "Login failed for user"; Category = 'AUTHENTICATION_FAILED' }
        @{ Text = "AADSTS7000215: Invalid client secret"; Category = 'AUTHENTICATION_FAILED' }
        @{ Text = "Msg 102 Incorrect syntax near 'x'"; Category = 'SQLCMD_FAILED' }
    ) {
        Get-SqlErrorClassification $Text | Should -Be $Category
    }
}

Describe 'Structured failures' {
    It 'carries every documented field' {
        $err = $null
        try {
            Stop-Deployment -Category 'UNSAFE_SCHEMA_CHANGE' -Message 'm' -Phase 'Tables' -ObjectType 'Table' `
                -ObjectName 'dbo.T' -File 'dbo/Tables/T.sql' -OriginalError 'e' -SuggestedAction 's'
        }
        catch { $err = $_ }
        $f = Get-DeploymentFailureFromError -ErrorRecord $err
        $f.Category | Should -Be 'UNSAFE_SCHEMA_CHANGE'
        $f.Phase | Should -Be 'Tables'
        $f.ObjectType | Should -Be 'Table'
        $f.ObjectName | Should -Be 'dbo.T'
        $f.File | Should -Be 'dbo/Tables/T.sql'
        $f.OriginalError | Should -Be 'e'
        $f.SuggestedAction | Should -Be 's'
    }
    It 'wraps unexpected exceptions as UNKNOWN_ERROR' {
        $err = $null
        try { throw 'boom' } catch { $err = $_ }
        (Get-DeploymentFailureFromError -ErrorRecord $err).Category | Should -Be 'UNKNOWN_ERROR'
    }
    It 'coerces unknown categories to UNKNOWN_ERROR' {
        (New-DeploymentFailure -Category 'NOPE' -Message 'x').Category | Should -Be 'UNKNOWN_ERROR'
    }
}

Describe 'Workflow command safety' {
    It 'escapes newlines and percent signs in annotations' {
        Format-WorkflowCommand -Command error -Message "a%b`nc" | Should -Be '::error::a%25b%0Ac'
    }
    It 'escapes file properties' {
        Format-WorkflowCommand -Command warning -Message 'm' -File 'a:b,c' | Should -Be '::warning file=a%3Ab%2Cc::m'
    }
    It 'prefixes annotation file paths with the warehouse folder' {
        $lines = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName ErrorHandling Write-Host { $lines.Add([string]$Object) }
        Set-AnnotationPathPrefix -Prefix './src\Sales.Warehouse/'
        try { Write-DeployLog -Level Warning -Message 'm' -File 'dbo/Views/v.sql' }
        finally { Set-AnnotationPathPrefix -Prefix '' }
        $lines[0] | Should -Be '::warning file=src/Sales.Warehouse/dbo/Views/v.sql::m'
    }
    It 'neutralises workflow commands embedded in untrusted log text' {
        $lines = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName ErrorHandling Write-Host { $lines.Add([string]$Object) }
        Write-DeployLog "ok`n::set-env name=X::y"
        $lines[0] | Should -Not -Match '(?m)^::'
    }
}

Describe 'Get-SqlcmdArgumentList' {
    BeforeAll {
        $script:conn = New-SqlConnectionInfo -SqlcmdPath '/x/sqlcmd' -Server 'abc.datawarehouse.fabric.microsoft.com' -Database 'Sales WH' `
            -ClientId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -TempDirectory '/tmp'
    }
    It 'always includes -b and service principal auth, never a password or token' {
        $a = Get-SqlcmdArgumentList -Connection $conn -InputFile '/tmp/f.sql'
        $a | Should -Contain '-b'
        $a | Should -Contain 'ActiveDirectoryServicePrincipal'
        $a | Should -Not -Contain '-P'
        $a[$a.IndexOf('-U') + 1] | Should -Be '11111111-1111-1111-1111-111111111111@22222222-2222-2222-2222-222222222222'
        $a[$a.IndexOf('-d') + 1] | Should -Be 'Sales WH'
        $a[$a.IndexOf('-i') + 1] | Should -Be '/tmp/f.sql'
    }
    It 'adds machine-readable flags for queries' {
        $a = Get-SqlcmdArgumentList -Connection $conn -InputFile 'f' -QueryOutput
        $a | Should -Contain '-W'
        $a[$a.IndexOf('-h') + 1] | Should -Be '-1'
    }
}

Describe 'Invoke-SqlcmdProcess exit-code handling' -Skip:($IsWindows) {
    BeforeAll {
        # A fake sqlcmd that prints to stderr and exits with the code in FAKE_EXIT.
        $script:fake = Join-Path ([System.IO.Path]::GetTempPath()) ("fake-sqlcmd-" + [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $fake -Value "#!/bin/sh`necho 'Msg 208, Invalid object name dbo.x' 1>&2`nexit `${FAKE_EXIT:-0}"
        & chmod +x $fake
        $script:tmp = [System.IO.Path]::GetTempPath()
        $script:conn = New-SqlConnectionInfo -SqlcmdPath $fake -Server 's' -Database 'd' `
            -ClientId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -TempDirectory $tmp
        $env:SQLCMDPASSWORD = 'not-a-real-secret'
    }
    AfterAll {
        Remove-Item -LiteralPath $fake -Force -ErrorAction SilentlyContinue
        Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_EXIT -ErrorAction SilentlyContinue
    }
    It 'reports failure from a non-zero exit code and captures stderr, even with ErrorActionPreference Stop' {
        $env:FAKE_EXIT = '1'
        $ErrorActionPreference = 'Stop'
        $r = Invoke-SqlText -Connection $conn -Sql 'SELECT 1'
        $r.Success | Should -BeFalse
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Invalid object name'
    }
    It 'reports success from exit code 0 even when stderr has text' {
        $env:FAKE_EXIT = '0'
        (Invoke-SqlText -Connection $conn -Sql 'SELECT 1').Success | Should -BeTrue
    }
    It 'removes its temporary SQL file' {
        $env:FAKE_EXIT = '0'
        $before = @(Get-ChildItem -LiteralPath $tmp -Filter 'wd-*.sql' -ErrorAction SilentlyContinue).Count
        $null = Invoke-SqlText -Connection $conn -Sql 'SELECT 1'
        @(Get-ChildItem -LiteralPath $tmp -Filter 'wd-*.sql' -ErrorAction SilentlyContinue).Count | Should -Be $before
    }
    It 'refuses to run without SQLCMDPASSWORD' {
        $saved = $env:SQLCMDPASSWORD
        Remove-Item Env:SQLCMDPASSWORD
        try { { Invoke-SqlText -Connection $conn -Sql 'SELECT 1' } | Should -Throw -ExpectedMessage '*SQLCMDPASSWORD*' }
        finally { $env:SQLCMDPASSWORD = $saved }
    }
}

Describe 'Fabric warehouse selection' {
    BeforeAll {
        $script:list = @(
            [pscustomobject]@{ id = 'a'; displayName = 'Sales' }
            [pscustomobject]@{ id = 'b'; displayName = 'Finance' }
        )
    }
    It 'selects by display name (case-insensitive)' {
        (Select-FabricWarehouse -Warehouses $list -WarehouseName 'sales').id | Should -Be 'a'
    }
    It 'fails with WAREHOUSE_NOT_FOUND and lists what is visible' {
        $err = $null
        try { Select-FabricWarehouse -Warehouses $list -WarehouseName 'Nope' } catch { $err = $_ }
        $err.Exception.Failure.Category | Should -Be 'WAREHOUSE_NOT_FOUND'
        $err.Exception.Failure.OriginalError | Should -Match 'Finance'
    }
    It 'fails on ambiguous names' {
        $dupes = $list + [pscustomobject]@{ id = 'c'; displayName = 'SALES' }
        { Select-FabricWarehouse -Warehouses $dupes -WarehouseName 'Sales' } | Should -Throw -ExpectedMessage '*ambiguous*'
    }
    It 'fails clearly on an empty workspace' {
        { Select-FabricWarehouse -Warehouses @() -WarehouseName 'Sales' } | Should -Throw -ExpectedMessage '*not found*'
    }
    It 'extracts a valid SQL endpoint and rejects injection-shaped values' {
        Get-WarehouseSqlEndpoint -WarehouseDetail ([pscustomobject]@{ properties = [pscustomobject]@{ connectionString = 'x.datawarehouse.fabric.microsoft.com' } }) |
            Should -Be 'x.datawarehouse.fabric.microsoft.com'
        Get-WarehouseSqlEndpoint -WarehouseDetail ([pscustomobject]@{ properties = [pscustomobject]@{ connectionString = '' } }) | Should -BeNullOrEmpty
        Get-WarehouseSqlEndpoint -WarehouseDetail ([pscustomobject]@{ id = 'x' }) | Should -BeNullOrEmpty
        { Get-WarehouseSqlEndpoint -WarehouseDetail ([pscustomobject]@{ properties = [pscustomobject]@{ connectionString = 'x -Q "drop"' } }) } |
            Should -Throw -ExpectedMessage '*unexpected format*'
    }
}

Describe 'Action outputs' {
    It 'writes every output with modern GITHUB_OUTPUT syntax' {
        $file = New-TemporaryFile
        try {
            $s = New-DeploymentStats -WarehouseName 'Sales'
            $s.WarehouseId = 'id-1'; $s.TablesCreated = 2; $s.ViewPasses = 3; $s.Status = 'SUCCESS'
            Publish-ActionOutputs -Stats $s -OutputFile $file.FullName
            $content = Get-Content -LiteralPath $file.FullName
            foreach ($k in 'warehouse-id', 'warehouse-name', 'tables-created', 'tables-existing', 'columns-added',
                'views-deployed', 'view-passes', 'unclassified-files', 'deployment-status') {
                $content | Should -Contain ($content | Where-Object { $_ -like "$k=*" })
                @($content | Where-Object { $_ -like "$k=*" }).Count | Should -Be 1
            }
            $content | Should -Contain 'tables-created=2'
            $content | Should -Contain 'deployment-status=SUCCESS'
        }
        finally { Remove-Item -LiteralPath $file.FullName -Force }
    }
    It 'strips newlines from values' {
        $file = New-TemporaryFile
        try {
            $s = New-DeploymentStats -WarehouseName "a`nb=c"
            Publish-ActionOutputs -Stats $s -OutputFile $file.FullName
            (Get-Content -LiteralPath $file.FullName) | Should -Contain 'warehouse-name=a b=c'
        }
        finally { Remove-Item -LiteralPath $file.FullName -Force }
    }
}

Describe 'Get-EntraAccessToken' {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot '../../scripts/modules/Authentication.psm1') -Force }

    It 'fails with AUTHENTICATION_FAILED and a suggested action when Entra rejects the credentials' {
        Mock -ModuleName Authentication Invoke-RestMethod { throw 'AADSTS7000215: Invalid client secret provided.' }
        $err = $null
        try {
            Get-EntraAccessToken -TenantId '22222222-2222-2222-2222-222222222222' -ClientId '33333333-3333-3333-3333-333333333333' `
                -ClientSecret 'wrong-secret-value' -Scope 'https://api.fabric.microsoft.com/.default'
        }
        catch { $err = $_ }
        $err.Exception.Failure.Category | Should -Be 'AUTHENTICATION_FAILED'
        $err.Exception.Failure.OriginalError | Should -Match 'AADSTS7000215'
        $err.Exception.Failure.SuggestedAction | Should -Match 'client-secret'
        ($err.Exception.Failure | ConvertTo-Json) | Should -Not -Match 'wrong-secret-value'
    }

    It 'fails when the response has no access token' {
        Mock -ModuleName Authentication Invoke-RestMethod { [pscustomobject]@{ token_type = 'Bearer' } }
        { Get-EntraAccessToken -TenantId 't' -ClientId 'c' -ClientSecret 's' -Scope 'x' } | Should -Throw -ExpectedMessage '*did not contain an access token*'
    }

    It 'returns the token from a successful response' {
        Mock -ModuleName Authentication Invoke-RestMethod { [pscustomobject]@{ access_token = 'tok' } }
        Get-EntraAccessToken -TenantId 't' -ClientId 'c' -ClientSecret 's' -Scope 'x' | Should -Be 'tok'
    }
}
