Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ErrorHandling.psm1')
Import-Module (Join-Path $PSScriptRoot 'SqlParsing.psm1')
Import-Module (Join-Path $PSScriptRoot 'SqlExecution.psm1')

<#
  Table deployment is additive-only.

    new table       -> run the Fabric-generated CREATE TABLE file unchanged
    existing table  -> never re-created; missing columns are added only when the
                       addition is provably safe (explicit NULL, no default,
                       identity, computed expression or inline constraint)

  Planning is separated from execution: every table is planned first, and if any
  plan contains an unsafe change the deployment stops before a single table DDL
  statement runs. Planning functions are pure and unit tested.
#>

$script:ConstraintLeadPattern = '^\s*(CONSTRAINT|PRIMARY\s+KEY|FOREIGN\s+KEY|UNIQUE|CHECK|INDEX|PERIOD\s+FOR)\b'

function ConvertFrom-CreateTableSql {
    <#
    .SYNOPSIS
      Parses the first CREATE TABLE statement into schema, name and column list.
    .OUTPUTS
      Schema, Name, Columns (Name, Definition, DataType, Nullability, HasDefault,
      IsIdentity, IsComputed, HasInlineConstraint), Constraints (raw text).
      Throws TABLE_PARSE_FAILED when the statement cannot be understood.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Sql,
        [string]$File = ''
    )

    $fail = {
        param([string]$why)
        Stop-Deployment -Category 'TABLE_PARSE_FAILED' -Phase 'Tables' -ObjectType 'Table' -File $File `
            -Message "Could not parse CREATE TABLE: $why" `
            -SuggestedAction 'Check the file is a single Fabric-generated CREATE TABLE statement. Please report parser gaps as an issue.'
    }

    $stmt = Find-SqlCreateStatement -Sql $Sql -ObjectKeyword 'TABLE'
    if (-not $stmt) { & $fail 'no CREATE TABLE statement found.' }

    $mask = Get-SqlCodeMask -Sql $Sql
    $after = $mask.Substring($stmt.NameEndIndex)
    $m = [regex]::Match($after, '^\s*\(')
    if (-not $m.Success) { & $fail 'expected "(" after the table name (CREATE TABLE AS SELECT is not supported).' }

    $open = $stmt.NameEndIndex + $m.Length - 1
    $close = Find-MatchingParenthesis -Mask $mask -OpenIndex $open
    if ($close -lt 0) { & $fail 'unbalanced parentheses in column list.' }

    $body = $Sql.Substring($open + 1, $close - $open - 1)
    $columns = [System.Collections.Generic.List[object]]::new()
    $constraints = [System.Collections.Generic.List[string]]::new()

    foreach ($piece in (Split-SqlTopLevel -Sql $body -Delimiter ',')) {
        $pieceMask = Get-SqlCodeMask -Sql $piece
        if ($pieceMask -match $script:ConstraintLeadPattern) {
            $constraints.Add($piece)
            continue
        }
        $columns.Add((ConvertFrom-ColumnDefinition -Text $piece -File $File))
    }

    if ($columns.Count -eq 0) { & $fail 'no column definitions found.' }

    $dupes = @($columns | Group-Object -Property Name -CaseSensitive | Where-Object Count -gt 1)
    if ($dupes.Count -gt 0) { & $fail "duplicate column name '$($dupes[0].Name)'." }

    return [pscustomobject]@{
        Schema      = $stmt.Schema
        Name        = $stmt.Name
        Columns     = $columns.ToArray()
        Constraints = $constraints.ToArray()
    }
}

function ConvertFrom-ColumnDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$File = ''
    )
    $mask = Get-SqlCodeMask -Sql $Text
    $ident = '(?:\[(?:[^\]]|\]\])+\]|"(?:[^"]|"")+"|[A-Za-z_@#][\w@#$]*)'
    $m = [regex]::Match($mask, "^\s*(?<name>$ident)")
    if (-not $m.Success) {
        Stop-Deployment -Category 'TABLE_PARSE_FAILED' -Phase 'Tables' -ObjectType 'Table' -File $File `
            -Message "Could not read a column name from definition: $Text"
    }

    $nameEnd = $m.Groups['name'].Index + $m.Groups['name'].Length
    $name = ConvertFrom-SqlIdentifier $Text.Substring($m.Groups['name'].Index, $m.Groups['name'].Length)
    $definition = $Text.Substring($nameEnd).Trim()
    $defMask = $mask.Substring($nameEnd)

    $typeMatch = [regex]::Match($defMask, "^\s*(?<type>$ident(?:\s*\.\s*$ident)?(?:\s*\([^)]*\))?)")
    $dataType = if ($typeMatch.Success -and $typeMatch.Groups['type'].Value -notmatch '^(?i)AS$') {
        $g = $typeMatch.Groups['type']
        ($Text.Substring($nameEnd + $g.Index, $g.Length) -replace '\s+', ' ').Trim()
    }
    else { '' }

    $nullability = if ($defMask -match '(?i)\bNOT\s+NULL\b') { 'NOT NULL' }
    elseif ($defMask -match '(?i)\bNULL\b') { 'NULL' }
    else { 'UNSPECIFIED' }

    return [pscustomobject]@{
        Name                = $name
        Definition          = $definition
        DataType            = $dataType
        Nullability         = $nullability
        HasDefault          = [bool]($defMask -match '(?i)\bDEFAULT\b')
        IsIdentity          = [bool]($defMask -match '(?i)\bIDENTITY\b')
        IsComputed          = [bool]($defMask -match '(?i)^\s*AS\b')
        HasInlineConstraint = [bool]($defMask -match '(?i)\b(PRIMARY\s+KEY|UNIQUE|REFERENCES|CHECK|FOREIGN\s+KEY|CONSTRAINT)\b')
    }
}

function Test-ColumnAdditionSafety {
    <# Returns $null when the column can be added safely, otherwise the reason. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Column)

    if ($Column.IsComputed) { return 'Computed columns are not automatically added in v0.1.' }
    if ($Column.IsIdentity) { return 'IDENTITY columns are not automatically added in v0.1.' }
    if ($Column.HasDefault) { return 'Columns with DEFAULT constraints are not automatically added in v0.1.' }
    if ($Column.HasInlineConstraint) { return 'Columns with inline constraints are not automatically added in v0.1.' }
    if ($Column.Nullability -eq 'NOT NULL') { return 'New NOT NULL columns are not automatically deployed in v0.1.' }
    if ($Column.Nullability -eq 'UNSPECIFIED') { return 'Nullability is not explicit; only columns declared NULL are added automatically.' }
    if (-not $Column.DataType) { return 'Could not determine the column data type.' }
    return $null
}

function New-AddColumnStatement {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Schema,
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][object]$Column
    )
    $target = (ConvertTo-SqlQuotedIdentifier $Schema) + '.' + (ConvertTo-SqlQuotedIdentifier $Table)
    # Definition text comes verbatim from the source; the terminator goes on its own
    # line so a trailing "-- comment" in the definition cannot swallow it.
    return "ALTER TABLE $target`nADD $(ConvertTo-SqlQuotedIdentifier $Column.Name) $($Column.Definition)`n;"
}

function Get-TableChangePlan {
    <#
    .SYNOPSIS
      Pure comparison of a parsed source table with the target's column names.
    .PARAMETER TargetColumns
      Column names currently in the target table.
    .OUTPUTS
      ExistingColumns, ColumnsToAdd (Column, Statement), TargetOnlyColumns,
      UnsafeChanges (Column, Reason). Nothing is executed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$SourceTable,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$TargetColumns
    )

    $existing = [System.Collections.Generic.List[string]]::new()
    $toAdd = [System.Collections.Generic.List[object]]::new()
    $unsafe = [System.Collections.Generic.List[object]]::new()

    foreach ($col in $SourceTable.Columns) {
        if ($TargetColumns -ccontains $col.Name) {
            $existing.Add($col.Name)
            continue
        }
        $caseOnly = @($TargetColumns | Where-Object { $_ -ieq $col.Name })
        if ($caseOnly.Count -gt 0) {
            # Could be a rename-by-case on a case-sensitive warehouse. Never guess.
            $unsafe.Add([pscustomobject]@{
                    Column = $col.Name
                    Reason = "Target has column '$($caseOnly[0])' differing only by case; renames are not automated in v0.1."
                })
            continue
        }
        $reason = Test-ColumnAdditionSafety -Column $col
        if ($reason) {
            $unsafe.Add([pscustomobject]@{ Column = $col.Name; Reason = $reason })
        }
        else {
            $toAdd.Add([pscustomobject]@{
                    Column    = $col
                    Statement = New-AddColumnStatement -Schema $SourceTable.Schema -Table $SourceTable.Name -Column $col
                })
        }
    }

    $sourceNames = @($SourceTable.Columns | ForEach-Object { $_.Name })
    $targetOnly = @($TargetColumns | Where-Object { $sourceNames -inotcontains $_ })

    return [pscustomobject]@{
        ExistingColumns   = $existing.ToArray()
        ColumnsToAdd      = $toAdd.ToArray()
        TargetOnlyColumns = $targetOnly
        UnsafeChanges     = $unsafe.ToArray()
    }
}

function Get-TargetTableColumns {
    <#
      One metadata round-trip for the whole warehouse:
      returns @{ 'schema.table' = [string[]] columns } keyed case-sensitively.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Connection)

    $rows = Invoke-SqlQuery -Connection $Connection -Phase 'Tables' -Sql @'
SELECT s.name, t.name, c.name
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
JOIN sys.columns AS c ON c.object_id = t.object_id
ORDER BY s.name, t.name, c.column_id;
'@
    $map = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::Ordinal)
    foreach ($r in $rows) {
        if ($r.Count -lt 3) { continue }
        $key = "$($r[0]).$($r[1])"
        if (-not $map.ContainsKey($key)) { $map[$key] = [System.Collections.Generic.List[string]]::new() }
        $map[$key].Add($r[2])
    }
    return $map
}

function New-TableDeploymentPlan {
    <#
    .SYNOPSIS
      Builds the plan for all table objects. Pure given $TargetTables (unit tested).
    .OUTPUTS
      Array of: Object, Action ('Create'|'Alter'|'NoChange'), Change (from
      Get-TableChangePlan, for existing tables).
      Throws UNSAFE_SCHEMA_CHANGE listing every unsafe change across all tables.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Tables,
        [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]$TargetTables
    )

    $plans = [System.Collections.Generic.List[object]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($obj in $Tables) {
        $key = "$($obj.Schema).$($obj.Name)"
        if (-not $TargetTables.ContainsKey($key)) {
            $caseMatch = @($TargetTables.Keys | Where-Object { $_ -ieq $key })
            if ($caseMatch.Count -gt 0) {
                $problems.Add("Table: $key`nFile: $($obj.RelativePath)`nReason: Target has table '$($caseMatch[0])' differing only by case; renames are not automated in v0.1.")
                continue
            }
            $plans.Add([pscustomobject]@{ Object = $obj; Action = 'Create'; Change = $null })
            continue
        }

        $source = ConvertFrom-CreateTableSql -Sql $obj.Sql -File $obj.RelativePath
        $change = Get-TableChangePlan -SourceTable $source -TargetColumns ([string[]]$TargetTables[$key])
        foreach ($u in $change.UnsafeChanges) {
            $problems.Add("Table: $key`nColumn: $($u.Column)`nFile: $($obj.RelativePath)`nReason: $($u.Reason)")
        }
        $action = if ($change.ColumnsToAdd.Count -gt 0) { 'Alter' } else { 'NoChange' }
        $plans.Add([pscustomobject]@{ Object = $obj; Action = $action; Change = $change })
    }

    if ($problems.Count -gt 0) {
        Stop-Deployment -Category 'UNSAFE_SCHEMA_CHANGE' -Phase 'Tables' -ObjectType 'Table' `
            -Message "$($problems.Count) table change(s) cannot be deployed automatically. No table changes were made." `
            -OriginalError ($problems -join "`n`n") `
            -SuggestedAction 'Provide an explicit migration strategy (e.g. add the column as NULL, backfill, then tighten), or deploy the change manually.'
    }
    return , $plans.ToArray()
}

function Invoke-TableDeployment {
    <#
    .SYNOPSIS
      Plans then executes the table phase. Returns counters for the summary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Tables,
        [Parameter(Mandatory)][object]$Stats
    )

    if ($Tables.Count -eq 0) { return }
    $target = Get-TargetTableColumns -Connection $Connection
    $plans = New-TableDeploymentPlan -Tables $Tables -TargetTables $target

    foreach ($p in $plans) {
        $obj = $p.Object
        $qualified = "$($obj.Schema).$($obj.Name)"
        switch ($p.Action) {
            'Create' {
                Write-DeployLog "[CREATE TABLE] $qualified"
                $r = Invoke-SqlFile -Connection $Connection -Path $obj.FullPath
                if (-not $r.Success) {
                    Stop-Deployment -Category (Get-SqlErrorClassification $r.Output) -Phase 'Tables' -ObjectType 'Table' `
                        -ObjectName $qualified -File $obj.RelativePath `
                        -Message "CREATE TABLE failed (sqlcmd exit code $($r.ExitCode))." -OriginalError $r.Output `
                        -SuggestedAction 'Fix the table definition in Fabric and re-sync to Git.'
                }
                $Stats.TablesCreated++
            }
            default {
                Write-DeployLog "[EXISTING TABLE] $qualified"
                $Stats.TablesExisting++
                foreach ($c in $p.Change.ExistingColumns) { Write-DeployLog -Level Debug "  [EXISTS] $c" }
                foreach ($c in $p.Change.TargetOnlyColumns) {
                    Write-DeployLog -Level Warning -File $obj.RelativePath -Message "Column $qualified.$c exists in the warehouse but not in source. It was NOT dropped."
                }
                foreach ($add in $p.Change.ColumnsToAdd) {
                    $colName = $add.Column.Name
                    Write-DeployLog "  [NEW COLUMN] $colName"
                    Write-DeployLog "  [ADD COLUMN] $qualified.$colName  ($($add.Column.DataType) NULL)"
                    $r = Invoke-SqlText -Connection $Connection -Sql $add.Statement
                    if (-not $r.Success) {
                        Stop-Deployment -Category (Get-SqlErrorClassification $r.Output) -Phase 'Tables' -ObjectType 'Column' `
                            -ObjectName "$qualified.$colName" -File $obj.RelativePath `
                            -Message "ALTER TABLE ADD failed (sqlcmd exit code $($r.ExitCode))." -OriginalError $r.Output
                    }
                    $Stats.ColumnsAdded++
                }
            }
        }
    }
}

Export-ModuleMember -Function ConvertFrom-CreateTableSql, ConvertFrom-ColumnDefinition, Test-ColumnAdditionSafety,
    New-AddColumnStatement, Get-TableChangePlan, Get-TargetTableColumns, New-TableDeploymentPlan, Invoke-TableDeployment
