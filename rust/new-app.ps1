#!/usr/bin/env pwsh
#Requires -Version 7.0
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9_]*$')]
    [string]$Name,
    [Parameter(Mandatory)]
    [string]$Destination,
    [string]$ProducerRoot,
    [string]$RustoloniaRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$templateDir = Join-Path $PSScriptRoot 'templates' 'avalonia-app'
if (-not (Test-Path -LiteralPath $templateDir -PathType Container)) {
    throw "Template directory not found at $templateDir"
}

$resolvedRustoloniaRoot = [System.IO.Path]::GetFullPath(
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RustoloniaRoot)
)
$resolvedProducerRoot = if ([string]::IsNullOrWhiteSpace($ProducerRoot)) {
    Join-Path $resolvedRustoloniaRoot 'avalonia-src'
} else {
    [System.IO.Path]::GetFullPath(
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProducerRoot)
    )
}

$destinationReference = if ([System.IO.Path]::IsPathRooted($Destination)) {
    $Destination
} else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
}
$resolvedDestination = [System.IO.Path]::GetFullPath($destinationReference)
$destinationParent = Split-Path -Parent $resolvedDestination
if (-not (Test-Path -LiteralPath $resolvedProducerRoot -PathType Container)) {
    throw "Producer root does not exist: $resolvedProducerRoot"
}
if (-not (Test-Path -LiteralPath $resolvedRustoloniaRoot -PathType Container)) {
    throw "Rustolonia root does not exist: $resolvedRustoloniaRoot"
}
if (Test-Path -LiteralPath $resolvedDestination -PathType Any) {
    throw "Destination '$resolvedDestination' already exists."
}

$producerDisplayPath = $resolvedProducerRoot.Replace('\', '/')
$rustoloniaDisplayPath = $resolvedRustoloniaRoot.Replace('\', '/')
$manifestDisplayPath = (Join-Path $resolvedDestination 'avalonia-app.json').Replace('\', '/')
$buildAppPath = Join-Path $resolvedRustoloniaRoot 'rust' 'build-app.ps1'
$buildCommand = @(
    'pwsh',
    ('"{0}"' -f $buildAppPath.Replace('\', '/')),
    '-ProducerRoot',
    ('"{0}"' -f $producerDisplayPath),
    '-Manifest',
    ('"{0}"' -f $manifestDisplayPath)
) -join ' '
$tempDestination = Join-Path $destinationParent ('.' + [System.IO.Path]::GetFileName($resolvedDestination) + '.tmp-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
    Copy-Item -LiteralPath $templateDir -Destination $tempDestination -Recurse

    $items = Get-ChildItem -LiteralPath $tempDestination -Recurse -File
    foreach ($item in $items) {
        $content = Get-Content -LiteralPath $item.FullName -Raw
        $content = $content.Replace('__AVALONIA_APP_NAME__', $Name)
        $content = $content.Replace('__AVALONIA_PRODUCER_ROOT__', $producerDisplayPath)
        $content = $content.Replace('__RUSTOLONIA_ROOT__', $rustoloniaDisplayPath)
        Set-Content -LiteralPath $item.FullName -Value $content -NoNewline
    }

    $gitIgnorePath = Join-Path $tempDestination '.gitignore'
    @(
        '.avalonia/',
        'bin/',
        'obj/',
        'target/',
        '*.user',
        '*.suo'
    ) | Set-Content -LiteralPath $gitIgnorePath -Encoding utf8

    Get-ChildItem -LiteralPath $tempDestination -Recurse -Directory -Filter 'target' |
        Remove-Item -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $tempDestination 'Cargo.lock') -ErrorAction SilentlyContinue

    Move-Item -LiteralPath $tempDestination -Destination $resolvedDestination
}
catch {
    if (Test-Path -LiteralPath $tempDestination -PathType Container) {
        Remove-Item -LiteralPath $tempDestination -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
}

Write-Host "Created '$Name' at $resolvedDestination."
Write-Host 'Next steps:'
Write-Host "  1. Pin '$producerDisplayPath' to the compatible Avalonia producer commit/submodule."
Write-Host "  2. $buildCommand"
