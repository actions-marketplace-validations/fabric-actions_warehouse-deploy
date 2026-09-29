Set-StrictMode -Version Latest

<#
  Lightweight T-SQL text utilities.

  This is deliberately NOT a SQL parser. It provides one primitive - a "code
  mask" - that blanks out comments and literals while preserving character
  offsets. Every regex in the engine runs against the mask, so keywords that
  appear inside comments, string literals or [bracketed identifiers] can never
  be matched, yet offsets found in the mask map 1:1 onto the original text.
#>

function Get-SqlCodeMask {
    <#
    .SYNOPSIS
      Returns $Sql with comments, string literals and quoted identifiers replaced
      by spaces (same length). Newlines are preserved so line numbers still match.
    .PARAMETER KeepIdentifiers
      When set, [bracketed] and "double-quoted" identifiers are left intact
      (only comments and string literals are blanked).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Sql,
        [switch]$KeepIdentifiers
    )

    $chars = $Sql.ToCharArray()
    $n = $chars.Length
    $i = 0

    # Blank a region but keep line breaks so line/offset bookkeeping stays valid.
    $blank = {
        param([int]$from, [int]$to)
        for ($k = $from; $k -lt $to -and $k -lt $n; $k++) {
            if ($chars[$k] -ne "`n" -and $chars[$k] -ne "`r") { $chars[$k] = ' ' }
        }
    }

    while ($i -lt $n) {
        $c = $chars[$i]
        $next = if ($i + 1 -lt $n) { $chars[$i + 1] } else { [char]0 }

        if ($c -eq '-' -and $next -eq '-') {
            $end = $i
            while ($end -lt $n -and $chars[$end] -ne "`n") { $end++ }
            & $blank $i $end
            $i = $end
            continue
        }

        if ($c -eq '/' -and $next -eq '*') {
            # T-SQL block comments nest.
            $depth = 1
            $end = $i + 2
            while ($end -lt $n -and $depth -gt 0) {
                if ($chars[$end] -eq '/' -and $end + 1 -lt $n -and $chars[$end + 1] -eq '*') { $depth++; $end += 2; continue }
                if ($chars[$end] -eq '*' -and $end + 1 -lt $n -and $chars[$end + 1] -eq '/') { $depth--; $end += 2; continue }
                $end++
            }
            & $blank $i $end
            $i = $end
            continue
        }

        if ($c -eq "'") {
            # String literal; '' is an escaped quote. N'...' prefix stays as code, harmless.
            $end = $i + 1
            while ($end -lt $n) {
                if ($chars[$end] -eq "'") {
                    if ($end + 1 -lt $n -and $chars[$end + 1] -eq "'") { $end += 2; continue }
                    $end++
                    break
                }
                $end++
            }
            # Keep the delimiters so the literal is still visibly a token boundary.
            & $blank ($i + 1) ([Math]::Max($i + 1, $end - 1))
            $i = $end
            continue
        }

        if ($c -eq '[' -or $c -eq '"') {
            $close = if ($c -eq '[') { ']' } else { '"' }
            $end = $i + 1
            while ($end -lt $n) {
                if ($chars[$end] -eq $close) {
                    if ($end + 1 -lt $n -and $chars[$end + 1] -eq $close) { $end += 2; continue }
                    $end++
                    break
                }
                $end++
            }
            if (-not $KeepIdentifiers) {
                # Replace identifier contents with a placeholder letter so the mask
                # still "sees" an identifier token (useful for regex word matching).
                for ($k = $i + 1; $k -lt $end - 1; $k++) {
                    if ($chars[$k] -ne "`n" -and $chars[$k] -ne "`r") { $chars[$k] = 'x' }
                }
            }
            $i = $end
            continue
        }

        $i++
    }

    return -join $chars
}

function ConvertFrom-SqlIdentifier {
    <# Removes [ ] or " " quoting from a single identifier part and unescapes. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Identifier)

    $id = $Identifier.Trim()
    if ($id.Length -ge 2 -and $id.StartsWith('[') -and $id.EndsWith(']')) {
        return $id.Substring(1, $id.Length - 2).Replace(']]', ']')
    }
    if ($id.Length -ge 2 -and $id.StartsWith('"') -and $id.EndsWith('"')) {
        return $id.Substring(1, $id.Length - 2).Replace('""', '"')
    }
    return $id
}

function ConvertTo-SqlQuotedIdentifier {
    <# Always bracket-quotes a name so generated DDL is safe for any identifier. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    return '[' + $Name.Replace(']', ']]') + ']'
}

function ConvertTo-SqlStringLiteral {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return "N'" + $Value.Replace("'", "''") + "'"
}

# One identifier part: [..]  ".."  or a regular identifier.
$script:IdentPartPattern = '(?:\[(?:[^\]]|\]\])+\]|"(?:[^"]|"")+"|[A-Za-z_@#][\w@#$]*)'
# Up to three-part name with optional whitespace around dots.
$script:MultiPartNamePattern = "$script:IdentPartPattern(?:\s*\.\s*$script:IdentPartPattern){0,2}"

function Split-SqlMultiPartName {
    <# Splits "[dbo].[My.Table]" into parts, respecting quoting. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Name)

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($Name, $script:IdentPartPattern)) {
        $parts.Add((ConvertFrom-SqlIdentifier $m.Value))
    }
    return , $parts.ToArray()
}

function Find-SqlCreateStatement {
    <#
    .SYNOPSIS
      Locates the first CREATE [OR ALTER] <ObjectKeyword> statement in real code
      (never inside comments/strings) and returns its position and object name.
    .OUTPUTS
      $null when not found, otherwise an object with:
        Index, Length          - span of the "CREATE [OR ALTER] <KEYWORD>" text
        IsCreateOrAlter        - already CREATE OR ALTER
        Schema, Name           - unquoted name parts (Schema defaults to 'dbo')
        NameEndIndex           - offset just after the object name
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Sql,
        [Parameter(Mandatory)][ValidateSet('TABLE', 'VIEW', 'PROCEDURE', 'FUNCTION', 'SCHEMA')][string]$ObjectKeyword
    )

    # Full mask: identifier contents become 'x' so a keyword inside [..] can never match,
    # while the bracket delimiters remain so the name pattern still spans the whole identifier.
    $mask = Get-SqlCodeMask -Sql $Sql
    $kw = if ($ObjectKeyword -eq 'PROCEDURE') { '(?:PROCEDURE|PROC)' } else { $ObjectKeyword }
    $pattern = "(?<![\w@#$])CREATE\s+(?<ora>OR\s+ALTER\s+)?$kw(?![\w@#$])\s*(?<name>$script:MultiPartNamePattern)"

    $m = [regex]::Match($mask, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return $null }

    $nameGroup = $m.Groups['name']
    # Offsets are identical between mask and source, so read the real name from the source.
    $parts = Split-SqlMultiPartName -Name $Sql.Substring($nameGroup.Index, $nameGroup.Length)

    $schema = 'dbo'
    $name = $parts[-1]
    if ($ObjectKeyword -eq 'SCHEMA') {
        $schema = $name
    }
    elseif ($parts.Count -ge 2) {
        $schema = $parts[-2]
    }

    return [pscustomobject]@{
        Index           = $m.Index
        Length          = $nameGroup.Index - $m.Index
        IsCreateOrAlter = $m.Groups['ora'].Success
        Schema          = $schema
        Name            = $name
        NameEndIndex    = $nameGroup.Index + $nameGroup.Length
    }
}

function Split-SqlTopLevel {
    <#
    .SYNOPSIS
      Splits $Sql on $Delimiter only where the delimiter is at parenthesis depth 0
      and not inside comments, strings or quoted identifiers.
      Returns the ORIGINAL text of each piece (trimmed), never the mask.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Sql,
        [char]$Delimiter = ','
    )

    $mask = Get-SqlCodeMask -Sql $Sql
    $pieces = [System.Collections.Generic.List[string]]::new()
    $depth = 0
    $start = 0
    for ($i = 0; $i -lt $mask.Length; $i++) {
        $c = $mask[$i]
        if ($c -eq '(') { $depth++ }
        elseif ($c -eq ')') { $depth-- }
        elseif ($c -eq $Delimiter -and $depth -eq 0) {
            $pieces.Add($Sql.Substring($start, $i - $start).Trim())
            $start = $i + 1
        }
    }
    $pieces.Add($Sql.Substring($start).Trim())
    return , @($pieces | Where-Object { $_ -ne '' })
}

function Find-MatchingParenthesis {
    <# Returns the index of the ')' matching the '(' at $OpenIndex in $Mask, or -1. #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Mask,
        [Parameter(Mandatory)][int]$OpenIndex
    )
    $depth = 0
    for ($i = $OpenIndex; $i -lt $Mask.Length; $i++) {
        if ($Mask[$i] -eq '(') { $depth++ }
        elseif ($Mask[$i] -eq ')') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }
    return -1
}

Export-ModuleMember -Function Get-SqlCodeMask, ConvertFrom-SqlIdentifier, ConvertTo-SqlQuotedIdentifier,
    ConvertTo-SqlStringLiteral, Split-SqlMultiPartName, Find-SqlCreateStatement, Split-SqlTopLevel,
    Find-MatchingParenthesis
