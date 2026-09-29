<#
  Runs scripts/deploy-warehouse.ps1 in a child pwsh process, exactly as the
  action does. Only paths that stop before any network call are exercised here;
  live Fabric behaviour is covered by the integration workflow.
#>
BeforeAll {
    $script:Entry = (Resolve-Path (Join-Path $PSScriptRoot '../../scripts/deploy-warehouse.ps1')).Path
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:Secret = 'unit-test-secret-value-9f8e7d'
    $script:Pwsh = (Get-Process -Id $PID).Path

    function Invoke-Entry([hashtable]$Inputs) {
        $out = New-TemporaryFile
        $saved = @{}
        $all = @{
            INPUT_WAREHOUSE_NAME   = 'SalesWarehouse'
            INPUT_WAREHOUSE_FOLDER = 'tests/fixtures/SalesWarehouse.Warehouse'
            INPUT_WORKSPACE_ID     = '11111111-1111-1111-1111-111111111111'
            INPUT_TENANT_ID        = '22222222-2222-2222-2222-222222222222'
            INPUT_CLIENT_ID        = '33333333-3333-3333-3333-333333333333'
            INPUT_CLIENT_SECRET    = $Secret
            GITHUB_WORKSPACE       = $RepoRoot
            GITHUB_OUTPUT          = $out.FullName
            # Off so ::add-mask:: lines (which contain the value by design) are not
            # emitted; the runner, not this test, is responsible for masking.
            GITHUB_ACTIONS         = 'false'
        }
        foreach ($k in $Inputs.Keys) { $all[$k] = $Inputs[$k] }
        foreach ($k in $all.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $all[$k]) }
        try {
            $log = & $Pwsh -NoProfile -NonInteractive -File $Entry 2>&1 | Out-String
            $code = $LASTEXITCODE
            $outputs = @{}
            foreach ($line in (Get-Content -LiteralPath $out.FullName)) { $k, $v = $line -split '=', 2; $outputs[$k] = $v }
            return [pscustomobject]@{ ExitCode = $code; Log = $log; Outputs = $outputs }
        }
        finally {
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
            Remove-Item -LiteralPath $out.FullName -Force
        }
    }
}

Describe 'deploy-warehouse.ps1 entry point' {
    It 'fails with INVALID_INPUT and non-zero exit when a required input is missing' {
        $r = Invoke-Entry @{ INPUT_WAREHOUSE_NAME = '' }
        $r.ExitCode | Should -Be 1
        $r.Log | Should -Match 'INVALID_INPUT'
        $r.Log | Should -Match "warehouse-name' is required"
        $r.Outputs['deployment-status'] | Should -Be 'FAILED'
        $r.Outputs['failure-category'] | Should -Be 'INVALID_INPUT'
    }

    It 'rejects non-GUID identifiers' {
        $r = Invoke-Entry @{ INPUT_TENANT_ID = 'contoso.onmicrosoft.com' }
        $r.ExitCode | Should -Be 1
        $r.Log | Should -Match "tenant-id' must be a GUID"
    }

    It 'rejects a warehouse-folder that escapes the workspace' {
        $r = Invoke-Entry @{ INPUT_WAREHOUSE_FOLDER = '../../../etc' }
        $r.ExitCode | Should -Be 1
        $r.Log | Should -Match 'must be inside the repository workspace'
    }

    It 'rejects an invalid max-view-passes' {
        $r = Invoke-Entry @{ INPUT_MAX_VIEW_PASSES = 'lots' }
        $r.ExitCode | Should -Be 1
        $r.Log | Should -Match 'max-view-passes'
    }

    It 'fails before authenticating when strict unclassified mode finds unknown SQL' {
        $r = Invoke-Entry @{ INPUT_FAIL_ON_UNCLASSIFIED_SQL = 'true' }
        $r.ExitCode | Should -Be 1
        $r.Log | Should -Match 'dbo/Unknown/Something.sql'
        $r.Log | Should -Match 'FABRIC WAREHOUSE DEPLOYMENT SUMMARY'
        $r.Outputs['failure-category'] | Should -Be 'UNCLASSIFIED_SQL'
        $r.Outputs['unclassified-files'] | Should -Be '1'
    }

    It 'never prints the client secret' {
        $r = Invoke-Entry @{ INPUT_FAIL_ON_UNCLASSIFIED_SQL = 'true'; INPUT_VERBOSE = 'true' }
        $r.Log | Should -Not -Match $Secret
    }
}
