Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ErrorHandling.psm1')
Import-Module (Join-Path $PSScriptRoot 'SqlParsing.psm1')
Import-Module (Join-Path $PSScriptRoot 'SqlExecution.psm1')

<#
  Deployment of "programmable" objects: views, functions, stored procedures.

  These share two mechanisms, which is why they live in one module:
    1. CREATE -> CREATE OR ALTER rewrite, applied in memory only (the Fabric
       source file is never modified). This is what makes re-deployment safe.
    2. Multi-pass execution: run everything pending; keep retrying the failures
       while each pass makes progress; stop when a pass makes none. This resolves
       dependency order without a SQL dependency graph and cannot loop forever
       (every continuing pass removes at least one item).
#>

$script:ObjectKeywordByType = @{
    'View'            = 'VIEW'
    'Function'        = 'FUNCTION'
    'StoredProcedure' = 'PROCEDURE'
}

$script:DisplayByType = @{
    'View'            = 'VIEW'
    'Function'        = 'FUNCTION'
    'StoredProcedure' = 'STORED PROCEDURE'
}

function ConvertTo-CreateOrAlterSql {
    <#
    .SYNOPSIS
      Rewrites the first real "CREATE <kind>" (outside comments/strings) to
      "CREATE OR ALTER <kind>". Already-CREATE-OR-ALTER SQL is returned unchanged.
      Returns $null when no CREATE <kind> statement is found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Sql,
        [ValidateSet('VIEW', 'PROCEDURE', 'FUNCTION')][string]$ObjectKeyword = 'VIEW'
    )
    $stmt = Find-SqlCreateStatement -Sql $Sql -ObjectKeyword $ObjectKeyword
    if (-not $stmt) { return $null }
    if ($stmt.IsCreateOrAlter) { return $Sql }
    # Replace exactly the 6 characters of the CREATE keyword; original casing and
    # whitespace of the remainder are preserved.
    return $Sql.Substring(0, $stmt.Index) + 'CREATE OR ALTER' + $Sql.Substring($stmt.Index + 6)
}

function Invoke-MultiPassDeployment {
    <#
    .SYNOPSIS
      Generic progress-bounded retry engine (pure apart from logging; unit tested
      with a fake executor).
    .PARAMETER Items
      Objects with at least QualifiedName and RelativePath.
    .PARAMETER Executor
      Scriptblock taking one item and returning an object with Success and Output.
    .PARAMETER MaxPasses
      Hard upper bound; 0 = automatic (item count, the theoretical maximum).
    .PARAMETER AbortCategories
      Error categories that stop immediately instead of being retried (e.g.
      authentication failures, where retrying cannot help).
    .OUTPUTS
      Success, Passes, Deployed (items), Failed (Item, Output, Category), StopReason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$Executor,
        [string]$Label = 'VIEW',
        [ValidateRange(0, 10000)][int]$MaxPasses = 0,
        [string[]]$AbortCategories = @('AUTHENTICATION_FAILED')
    )

    $limit = if ($MaxPasses -gt 0) { $MaxPasses } else { [Math]::Max(1, $Items.Count) }
    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($i in $Items) { $pending.Add($i) }
    $deployed = [System.Collections.Generic.List[object]]::new()
    $failures = @()
    $pass = 0
    $stopReason = ''

    while ($pending.Count -gt 0) {
        if ($pass -ge $limit) {
            $stopReason = "Maximum number of passes ($limit) reached."
            break
        }
        $pass++
        Write-DeployBanner -Title "$Label DEPLOYMENT PASS $pass"

        $failures = @()
        $succeeded = 0
        $abort = $false
        foreach ($item in $pending) {
            Write-DeployLog ''
            Write-DeployLog "[$Label] $($item.QualifiedName)"
            $r = & $Executor $item
            if ($r.Success) {
                Write-DeployLog 'SUCCESS'
                $deployed.Add($item)
                $succeeded++
                continue
            }
            $category = Get-SqlErrorClassification ([string]$r.Output)
            Write-DeployLog 'DEFERRED'
            Write-DeployLog -Level Debug "  $($r.Output)"
            $failures += [pscustomobject]@{ Item = $item; Output = [string]$r.Output; Category = $category }
            if ($AbortCategories -contains $category) { $abort = $true; break }
        }

        Write-DeployLog ''
        Write-DeployLog 'Pass result:'
        Write-DeployLog "$succeeded successful"
        Write-DeployLog "$($failures.Count) deferred"

        if ($abort) {
            $stopReason = 'A non-retryable error occurred.'
            break
        }

        $pending = [System.Collections.Generic.List[object]]::new()
        foreach ($f in $failures) { $pending.Add($f.Item) }

        if ($pending.Count -gt 0 -and $succeeded -eq 0) {
            $stopReason = 'No progress in the last pass: the remaining failures cannot be fixed by reordering (missing dependency, invalid SQL or circular reference).'
            break
        }
    }

    return [pscustomobject]@{
        Success    = ($pending.Count -eq 0)
        Passes     = $pass
        Deployed   = $deployed.ToArray()
        Failed     = if ($pending.Count -eq 0) { @() } else { @($failures) }
        StopReason = $stopReason
    }
}

function Write-MultiPassFailure {
    param([Parameter(Mandatory)][object]$Result, [string]$Label = 'VIEW')

    Write-DeployBanner -Title "$Label DEPLOYMENT FAILED"
    Write-DeployLog $Result.StopReason
    foreach ($f in $Result.Failed) {
        Write-DeployLog ''
        Write-DeployLog $f.Item.RelativePath
        Write-DeployLog ''
        Write-DeployLog 'SQL ERROR:'
        foreach ($l in ($f.Output -split "`r?`n")) { if ($l.Trim()) { Write-DeployLog "  $l" } }
        Write-DeployLog ''
        Write-DeployLog 'Classification:'
        Write-DeployLog (Get-FailureCategoryForObject -Category $f.Category)
        # Annotate with the message line, not the "Msg 208, Level 16, State 1" header.
        $lines = @($f.Output -split "`r?`n" | Where-Object { $_.Trim() })
        $message = @($lines | Where-Object { $_ -notmatch '^\s*Msg \d+, Level' }) + $lines | Select-Object -First 1
        Write-DeployLog -Level Error -File $f.Item.RelativePath -Message "$($f.Item.QualifiedName): $message"
    }
}

function Get-FailureCategoryForObject {
    <# Generic sqlcmd failures of object DDL are reported as dependency-or-invalid-SQL. #>
    param([string]$Category)
    if ($Category -eq 'SQLCMD_FAILED') { return 'UNRESOLVED_DEPENDENCY_OR_INVALID_SQL' }
    return $Category
}

function Invoke-ProgrammableObjectDeployment {
    <#
    .SYNOPSIS
      Deploys views, functions or procedures with CREATE OR ALTER + multi-pass.
      Returns the multi-pass result; throws a structured failure if not all
      objects deployed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Connection',
        Justification = 'Read by $executor through dynamic scoping.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Objects,
        [Parameter(Mandatory)][ValidateSet('View', 'Function', 'StoredProcedure')][string]$ObjectType,
        [Parameter(Mandatory)][object]$Stats,
        [int]$MaxPasses = 0
    )

    $keyword = $script:ObjectKeywordByType[$ObjectType]
    $label = $script:DisplayByType[$ObjectType]

    $executor = {
        param($item)
        $sql = ConvertTo-CreateOrAlterSql -Sql $item.Sql -ObjectKeyword $keyword
        if ($null -eq $sql) {
            return [pscustomobject]@{ Success = $false; Output = "No CREATE $keyword statement found in $($item.RelativePath)." }
        }
        return Invoke-SqlText -Connection $Connection -Sql $sql
    }
    # No GetNewClosure(): that would rebind the block outside this module's session
    # state. Invoked from Invoke-MultiPassDeployment (same module) it sees
    # $keyword and $Connection through normal dynamic scoping.

    $result = Invoke-MultiPassDeployment -Items $Objects -Executor $executor -Label $label -MaxPasses $MaxPasses

    # Record progress before a possible throw so the failure summary is accurate.
    switch ($ObjectType) {
        'View' { $Stats.ViewsDeployed = $result.Deployed.Count; $Stats.ViewPasses = $result.Passes }
        'Function' { $Stats.FunctionsProcessed = $result.Deployed.Count }
        'StoredProcedure' { $Stats.ProceduresProcessed = $result.Deployed.Count }
    }

    if (-not $result.Success) {
        Write-MultiPassFailure -Result $result -Label $label
        $first = $result.Failed | Select-Object -First 1
        $category = if ($ObjectType -eq 'View') { 'VIEW_DEPLOYMENT_FAILED' } else { Get-FailureCategoryForObject -Category $first.Category }
        $details = ($result.Failed | ForEach-Object {
                "$($_.Item.RelativePath) [$(Get-FailureCategoryForObject -Category $_.Category)]`n$($_.Output)"
            }) -join "`n`n"
        Stop-Deployment -Category $category -Phase "${ObjectType}s" -ObjectType $ObjectType `
            -ObjectName (($result.Failed | ForEach-Object { $_.Item.QualifiedName }) -join ', ') `
            -File $first.Item.RelativePath `
            -Message "$($result.Failed.Count) $($label.ToLower()) object(s) could not be deployed after $($result.Passes) pass(es). $($result.StopReason)" `
            -OriginalError $details `
            -SuggestedAction 'Fix the SQL errors above. Missing objects must exist in the warehouse folder or already exist in the target.'
    }
    return $result
}

Export-ModuleMember -Function ConvertTo-CreateOrAlterSql, Invoke-MultiPassDeployment, Invoke-ProgrammableObjectDeployment
