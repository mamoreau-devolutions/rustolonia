#!/usr/bin/env pwsh
#Requires -Version 7.0
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9_]*$')]
    [string]$Name,
    [Parameter(Mandatory)]
    [string]$Destination,
    [string]$ProducerRoot,
    # The rustolonia repository root (defaults to the checkout this script lives in).
    [string]$RustoloniaRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$templateDir = Join-Path $PSScriptRoot 'templates' 'avalonia-app'
if (-not (Test-Path $templateDir))
{
    throw "Template directory not found at $templateDir"
}
if (Test-Path $Destination)
{
    throw "Destination '$Destination' already exists."
}

Copy-Item $templateDir $Destination -Recurse
Get-ChildItem -Path $Destination -Recurse -Directory -Filter "target" |
    Remove-Item -Recurse -Force
Remove-Item -Path (Join-Path $Destination "Cargo.lock") -ErrorAction SilentlyContinue

$cargoToml = Join-Path $Destination "Cargo.toml"
$producerPath = (Resolve-Path $ProducerRoot).Path.Replace('\', '/')
Get-ChildItem -Path $Destination -Recurse -File | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    $rustoloniaPath = (Resolve-Path $RustoloniaRoot).Path.Replace('\', '/')
    $content = $content.Replace("__AVALONIA_APP_NAME__", $Name).Replace("__AVALONIA_PRODUCER_ROOT__", $producerPath).Replace("__RUSTOLONIA_ROOT__", $rustoloniaPath)
    Set-Content -Path $_.FullName -Value $content -NoNewline
}

Write-Host "Created '$Name' at $Destination."
Write-Host "Next steps:"
Write-Host "  1. Pin '$producerPath' to the compatible Avalonia producer commit/submodule."
Write-Host ('  2. pwsh "{0}/rust/build-app.ps1" -ProducerRoot "{2}" -Manifest "{1}/avalonia-app.json"' -f $rustoloniaPath, ($Destination -replace '\', '/'), $producerPath ($Destination -replace '\\', '/'))
