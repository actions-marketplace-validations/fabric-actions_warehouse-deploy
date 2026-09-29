<#
.SYNOPSIS
  Composes an integration scenario: the base warehouse folder overlaid with the
  scenario's changed files. Output goes under the workspace (the action refuses
  folders outside it) and is never committed.
#>
param(
    [Parameter(Mandatory)][ValidateSet('base', 'add-column', 'broken-dependency', 'not-null')][string]$Scenario
)
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot 'scenarios'
$target = Join-Path $env:GITHUB_WORKSPACE "_it/$Scenario"
if (Test-Path $target) { Remove-Item $target -Recurse -Force }
New-Item -ItemType Directory -Path $target | Out-Null
Copy-Item -Path (Join-Path $root 'base/WdIt.Warehouse') -Destination $target -Recurse
if ($Scenario -ne 'base') {
    Copy-Item -Path (Join-Path $root "$Scenario/*") -Destination (Join-Path $target 'WdIt.Warehouse') -Recurse -Force
}
"folder=_it/$Scenario/WdIt.Warehouse" | Add-Content -LiteralPath $env:GITHUB_OUTPUT
