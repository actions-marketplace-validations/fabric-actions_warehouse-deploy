<#
.SYNOPSIS
  Static validation run by CI (and locally): PowerShell syntax, PSScriptAnalyzer,
  and action.yml structure. Exits non-zero on any problem.
#>
[CmdletBinding()]
param([switch]$SkipAnalyzer)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$problems = [System.Collections.Generic.List[string]]::new()

# 1. Syntax: parse every PowerShell file.
$psFiles = Get-ChildItem -Path $root -Recurse -File -Include '*.ps1', '*.psm1' | Where-Object FullName -notmatch '[\\/]\.git[\\/]'
foreach ($f in $psFiles) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in $errors) { $problems.Add("SYNTAX $($f.Name):$($e.Extent.StartLineNumber) $($e.Message)") }
}
Write-Host "Parsed $($psFiles.Count) PowerShell file(s)."

# 2. PSScriptAnalyzer (errors and warnings).
if (-not $SkipAnalyzer) {
    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    $results = Invoke-ScriptAnalyzer -Path (Join-Path $root 'scripts') -Recurse -Settings $settings
    foreach ($r in $results) { $problems.Add("LINT $($r.ScriptName):$($r.Line) [$($r.RuleName)] $($r.Message)") }
    Write-Host "PSScriptAnalyzer findings: $(@($results).Count)"
}

# 3. action.yml structure (line-based: avoids a YAML module dependency).
$actionPath = Join-Path $root 'action.yml'
$action = Get-Content -LiteralPath $actionPath -Raw
foreach ($key in 'name:', 'description:', 'author:', 'branding:', 'inputs:', 'outputs:', 'runs:') {
    if ($action -notmatch "(?m)^$([regex]::Escape($key))") { $problems.Add("ACTION missing top-level '$key'") }
}
# Valid Marketplace branding values (subset check: the ones we use).
if ($action -notmatch '(?m)^\s+icon:\s*"database"') { $problems.Add('ACTION branding.icon must be "database"') }
$validColors = 'white', 'black', 'yellow', 'blue', 'green', 'orange', 'red', 'purple', 'gray-dark'
$color = [regex]::Match($action, '(?m)^\s+color:\s*"([^"]+)"').Groups[1].Value
if ($validColors -notcontains $color) { $problems.Add("ACTION branding.color '$color' is not a valid Marketplace colour") }
if ($action -match '::set-output') { $problems.Add('ACTION uses deprecated ::set-output') }
if ($action -match 'run:[^\n]*\$\{\{\s*inputs\.') { $problems.Add('ACTION interpolates inputs directly into run: (script injection risk)') }

# Every output the script publishes must be declared in action.yml, and vice versa.
Import-Module (Join-Path $root 'scripts/modules/DeploymentReport.psm1') -Force
$published = @((Get-ActionOutputMap -Stats (New-DeploymentStats)).Keys)
$declared = [regex]::Matches($action, '(?m)^  ([a-z-]+):\s*\r?\n\s+description:[^\n]*\r?\n\s+value:') | ForEach-Object { $_.Groups[1].Value }
foreach ($o in $published) { if ($declared -notcontains $o) { $problems.Add("ACTION output '$o' is published but not declared") } }
foreach ($o in $declared) {
    if ($published -notcontains $o) { $problems.Add("ACTION output '$o' is declared but never published") }
    if ($action -notmatch "steps\.deploy\.outputs\.$([regex]::Escape($o)) \}\}") { $problems.Add("ACTION output '$o' does not map to steps.deploy.outputs.$o") }
}

# Every INPUT_* the script reads must be set by action.yml.
$script = Get-Content -LiteralPath (Join-Path $root 'scripts/deploy-warehouse.ps1') -Raw
$read = [regex]::Matches($script, "Get-Input '([A-Z_]+)'|'INPUT_([A-Z_]+)'") | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } } | Sort-Object -Unique
foreach ($i in $read) {
    $inputName = $i.ToLower().Replace('_', '-')
    if ($action -notmatch "INPUT_$($i): \$\{\{ inputs\.$([regex]::Escape($inputName)) \}\}") { $problems.Add("ACTION does not pass INPUT_$i from inputs.$inputName") }
    if ($action -notmatch "(?m)^  $([regex]::Escape($inputName)):") { $problems.Add("ACTION input '$inputName' not declared") }
}

if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host "::error::$_" }
    Write-Host "$($problems.Count) problem(s) found."
    exit 1
}
Write-Host 'Repository validation passed.'
