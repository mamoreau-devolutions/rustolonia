#!/usr/bin/env pwsh
#Requires -Version 7.0
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$SkipManagedBuild,
    [switch]$Test,
    [switch]$ValidateTemplate,
    [string]$PackageRid
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
# rust/<script> -> the Avalonia repository root is three levels up
$repositoryRoot = Split-Path -Parent $PSScriptRoot

Write-Host '==> [1/4] Regenerating object-model projection IR, C# COM sources, and native ABI header'
dotnet run --project (Join-Path $repositoryRoot 'projection' 'Avalonia.Projection.Tool') -c $Configuration -- `
    (Join-Path $repositoryRoot 'rust' 'projection.ir.json') `
    (Join-Path $repositoryRoot 'host' 'Generated' 'ObjectModel') `
    (Join-Path $repositoryRoot 'rust' 'avalonia-sys' 'include' 'avalonia-rust-abi.h')
if ($LASTEXITCODE -ne 0)
{
    exit $LASTEXITCODE
}

Write-Host "==> [1/4] Regenerating Rust sys/safe bindings from projection IR"
Push-Location "$repositoryRoot\rust"
try
{
    cargo run -p avalonia-bindgen -- `
        (Join-Path '.' 'projection.ir.json') `
        (Join-Path '.' 'avalonia-sys' 'src' 'generated.rs') `
        (Join-Path '.' 'avalonia' 'src' 'generated.rs')
    if ($LASTEXITCODE -ne 0)
    {
        exit $LASTEXITCODE
    }
}
finally
{
    Pop-Location
}

Write-Host "==> [1/4] Regenerating view-model adapters/registry/Rust model/contract from the canonical view-model IR"
dotnet run --project (Join-Path $repositoryRoot 'projection' 'Avalonia.ViewModelProjection.Tool') -c $Configuration -- `
    (Join-Path $repositoryRoot 'rust' 'view-model.ir.json') `
    (Join-Path $repositoryRoot 'samples' 'RustViewModelSample.Managed' 'Generated') `
    (Join-Path $repositoryRoot 'host' 'Generated' 'ViewModels') `
    (Join-Path $repositoryRoot 'rust' 'avalonia' 'src' 'generated_view_models.rs') `
    (Join-Path $repositoryRoot 'rust' 'view-model.contract.md')
if ($LASTEXITCODE -ne 0)
{
    exit $LASTEXITCODE
}

Push-Location "$repositoryRoot\rust"
try
{
    cargo fmt --all
    if ($LASTEXITCODE -ne 0)
    {
        exit $LASTEXITCODE
    }
}
finally
{
    Pop-Location
}

if (-not $SkipManagedBuild)
{
    Write-Host "==> [2/4] Building managed AXAML (RustViewModelSample.Managed via Avalonia.Host)"
    dotnet build (Join-Path $repositoryRoot 'host' 'Avalonia.Host.csproj') -c $Configuration
    if ($LASTEXITCODE -ne 0)
    {
        exit $LASTEXITCODE
    }
}

Write-Host "==> [3/4] Building the Rust workspace"
$cargoArgs = @('--manifest-path', (Join-Path $repositoryRoot 'rust' 'Cargo.toml'), '--workspace')
if ($Test)
{
    cargo test @cargoArgs
}
else
{
    cargo build @cargoArgs
}
if ($LASTEXITCODE -ne 0)
{
    exit $LASTEXITCODE
}

if ($ValidateTemplate)
{
    Write-Host "==> [3/4] Validating the external consumer template compiles standalone"
    $templateConsumer = Join-Path $repositoryRoot 'rust' 'target' 'template-validation'
    Remove-Item $templateConsumer -Recurse -Force -ErrorAction SilentlyContinue
    $producerRoot = Join-Path $repositoryRoot 'avalonia-src'
    & (Join-Path $PSScriptRoot 'new-app.ps1') -Name template_validation -Destination $templateConsumer -ProducerRoot $producerRoot -RustoloniaRoot $repositoryRoot
    dotnet run --project (Join-Path $repositoryRoot 'projection' 'Avalonia.ViewModelProjection.Tool') -c $Configuration -- `
        (Join-Path $templateConsumer 'view-model.ir.json') `
        (Join-Path $templateConsumer 'managed' 'Generated') `
        (Join-Path $templateConsumer 'generated') `
        (Join-Path $templateConsumer 'generated' 'generated_view_models.rs') `
        (Join-Path $templateConsumer 'generated' 'view-model.contract.md') `
        --external-rust
    cargo check --manifest-path (Join-Path $templateConsumer 'Cargo.toml')
    if ($LASTEXITCODE -ne 0)
    {
        exit $LASTEXITCODE
    }
    Remove-Item $templateConsumer -Recurse -Force
}

if ($PackageRid)
{
    Write-Host "==> [4/4] Packaging the NativeAOT host and a Rust example for $PackageRid"
    & "$PSScriptRoot\package.ps1" -Rid $PackageRid -Configuration $Configuration
    if ($LASTEXITCODE -ne 0)
    {
        exit $LASTEXITCODE
    }
}

Write-Host "Regeneration and build complete."
