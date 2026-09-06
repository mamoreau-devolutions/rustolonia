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

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$producerRoot = Join-Path $root 'avalonia-src'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('rustolonia-test-build-app-' + [guid]::NewGuid().ToString('N'))
$externalRoot = Join-Path $scratch 'external app directory'
$constructedApp = Join-Path $externalRoot 'My App'
New-Item -ItemType Directory -Force -Path $externalRoot | Out-Null
$producerPath = $producerRoot.Replace('\', '/')
$rustoloniaPath = $root.Replace('\', '/')

try {
    $scriptOutput = & (Join-Path $root 'rust' 'new-app.ps1') -Name 'demo_app' -Destination $constructedApp -ProducerRoot $producerRoot -RustoloniaRoot $root 6>&1
    $scriptText = ($scriptOutput | Out-String)
    $buildAppPath = (Join-Path $root 'rust' 'build-app.ps1').Replace('\', '/')
    $manifestPath = (Join-Path $constructedApp 'avalonia-app.json').Replace('\', '/')
    $expectedBuildCommand = "pwsh `"$buildAppPath`" -ProducerRoot `"$producerPath`" -Manifest `"$manifestPath`""
    Assert-True ($scriptText.Contains($expectedBuildCommand)) 'printed scaffold command should preserve exact path values without injected whitespace'

    Assert-True (Test-Path -LiteralPath $constructedApp -PathType Container) 'scaffold destination should be created'
    $cargoPath = Join-Path $constructedApp 'Cargo.toml'
    $cargoText = Get-Content -LiteralPath $cargoPath -Raw
    Assert-True ($cargoText.Contains("path = `"$rustoloniaPath/rust/avalonia`"")) 'Cargo.toml should resolve the Rustolonia root'
    Assert-True (-not $cargoText.Contains('__RUSTOLONIA_ROOT__')) 'Cargo.toml should not keep the placeholder after scaffolding'
    Assert-True ($cargoText.Contains("path = `"$rustoloniaPath/rust/avalonia`"")) 'scaffold should not fall back to producer checkout'

    $projectPath = Join-Path $constructedApp 'managed' 'Consumer.Presentation.csproj'
    $projectText = Get-Content -LiteralPath $projectPath -Raw
    Assert-True ($projectText.Contains($producerPath)) 'managed presentation should resolve the producer root'
    Assert-True ($projectText.Contains($rustoloniaPath)) 'managed presentation should resolve the Rustolonia root'
    Assert-True (-not $projectText.Contains('__AVALONIA_PRODUCER_ROOT__')) 'managed presentation should not retain the producer placeholder'
    Assert-True (-not $projectText.Contains('__RUSTOLONIA_ROOT__')) 'managed presentation should not retain the Rustolonia placeholder'

    $badProducer = Join-Path $scratch 'missing-producer'
    $errorText = ''
    try { & (Join-Path $root 'rust' 'new-app.ps1') -Name 'duplicate_app' -Destination (Join-Path $externalRoot 'will-fail') -ProducerRoot $badProducer -RustoloniaRoot $root } catch { $errorText = "$_" }
    Assert-True ($errorText -match 'does not exist') 'invalid producer roots should be rejected before any files are created'

    $dupError = ''
    try { & (Join-Path $root 'rust' 'new-app.ps1') -Name 'demo_app' -Destination $constructedApp -ProducerRoot $producerRoot -RustoloniaRoot $root } catch { $dupError = "$_" }
    Assert-True ($dupError -match 'already exists') 'existing destinations must be preserved and fail cleanly'

    foreach ($relative in @('managed/App.csproj', 'view-model.ir.json', 'Cargo.toml')) {
        $path = Join-Path $scratch $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        Set-Content -LiteralPath $path -Value '' -NoNewline
    }
    $manifest = @{
        version                    = 1
        presentationProject        = 'managed/App.csproj'
        viewModelIr                = 'view-model.ir.json'
        generatedAdaptersDirectory = 'managed/Generated'
        generatedRegistryFile      = 'generated/RustViewRegistry.g.cs'
        generatedRustFile          = 'generated/generated.rs'
        generatedContractFile      = 'generated/contract.md'
        cargoManifest              = 'Cargo.toml'
        packageName                = 'consumer'
        rid                        = 'win-x64'
        configuration              = 'Release'
        outputDirectory            = 'artifacts/win-x64'
    }
    $manifestPath = Join-Path $scratch 'avalonia-app.json'
    ($manifest | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $manifestPath -Encoding utf8

    $bad = $manifest.Clone()
    $bad['unexpected'] = $true
    $badPath = Join-Path $scratch 'bad.json'
    ($bad | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $badPath -Encoding utf8
    $badError = ''
    try { & (Join-Path $root 'rust' 'build-app.ps1') -ProducerRoot $producerRoot -Manifest $badPath } catch { $badError = "$_" }
    Assert-True ($badError -match 'unknown field') 'unknown field must be rejected'

    $bundle = Join-Path $scratch 'bundle'
    New-Item -ItemType Directory -Path $bundle | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $bundle 'z.bin'), [byte[]](0x7A))
    [IO.File]::WriteAllBytes((Join-Path $bundle 'a.bin'), [byte[]](0x61))
    & (Join-Path $root 'rust' 'generate-sbom.ps1') -Rid 'win-x64' -Bundle $bundle
    $first = [IO.File]::ReadAllBytes((Join-Path $bundle 'sbom.cdx.json'))
    & (Join-Path $root 'rust' 'generate-sbom.ps1') -Rid 'win-x64' -Bundle $bundle
    $second = [IO.File]::ReadAllBytes((Join-Path $bundle 'sbom.cdx.json'))
    Assert-True ($first.Length -eq $second.Length -and [Linq.Enumerable]::SequenceEqual($first, $second)) 'SBOM must be repeatable'
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) { throw "$failed assertion(s) failed" }
Write-Host 'test-build-app.ps1 passed'
