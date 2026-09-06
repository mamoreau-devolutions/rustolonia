#!/usr/bin/env pwsh
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        Write-Error $Message
        $script:failed++
    }
}

$root = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path $PSScriptRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    foreach ($relative in @('managed/App.csproj', 'view-model.ir.json', 'Cargo.toml')) {
        $path = Join-Path $scratch $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        Set-Content -LiteralPath $path -Value '' -NoNewline
    }
    $manifest = @{
        version                     = 1
        presentationProject         = 'managed/App.csproj'
        viewModelIr                 = 'view-model.ir.json'
        generatedAdaptersDirectory  = 'managed/Generated'
        generatedRegistryFile       = 'generated/RustViewRegistry.g.cs'
        generatedRustFile           = 'generated/generated.rs'
        generatedContractFile       = 'generated/contract.md'
        cargoManifest               = 'Cargo.toml'
        packageName                 = 'consumer'
        rid                         = 'win-x64'
        configuration               = 'Release'
        outputDirectory             = 'artifacts/win-x64'
    }
    $manifestPath = Join-Path $scratch 'avalonia-app.json'
    ($manifest | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $manifestPath -Encoding utf8

    # Manifest parsing is exercised by invoking build-app until it fails on producer files;
    # unknown-field rejection is checked by injecting an extra key.
    $bad = $manifest.Clone()
    $bad['unexpected'] = $true
    $badPath = Join-Path $scratch 'bad.json'
    ($bad | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $badPath -Encoding utf8
    $errorText = ''
    $avaloniaRoot = Join-Path $root 'avalonia-src'
    try { & (Join-Path $root 'build-app.ps1') -ProducerRoot $avaloniaRoot -Manifest $badPath } catch { $errorText = "$_" }
    Assert-True ($errorText -match 'unknown field') 'unknown field must be rejected'

    $bundle = Join-Path $scratch 'bundle'
    New-Item -ItemType Directory -Path $bundle | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $bundle 'z.bin'), [byte[]](0x7A))
    [IO.File]::WriteAllBytes((Join-Path $bundle 'a.bin'), [byte[]](0x61))
    & (Join-Path $root 'generate-sbom.ps1') -Rid 'win-x64' -Bundle $bundle
    $first = [IO.File]::ReadAllBytes((Join-Path $bundle 'sbom.cdx.json'))
    & (Join-Path $root 'generate-sbom.ps1') -Rid 'win-x64' -Bundle $bundle
    $second = [IO.File]::ReadAllBytes((Join-Path $bundle 'sbom.cdx.json'))
    Assert-True ($first.Length -eq $second.Length -and [Linq.Enumerable]::SequenceEqual($first, $second)) 'SBOM must be repeatable'
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) { throw "$failed assertion(s) failed" }
Write-Host 'test-build-app.ps1 passed'
