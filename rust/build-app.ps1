#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
Build and package an external Rust/AXAML consumer against a pinned producer.
#>
param(
    [Parameter(Mandatory)][string]$ProducerRoot,
    [Parameter(Mandatory)][string]$Manifest,
    # The rustolonia repository root (defaults to the checkout this script lives in).
    [string]$RustoloniaRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$SkipGenerate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$script:RidTargets = @{
    'win-x64'     = @{ Triple = 'x86_64-pc-windows-msvc'; Platform = 'Win32'; HostExtension = '.dll'; ExeExtension = '.exe' }
    'win-arm64'   = @{ Triple = 'aarch64-pc-windows-msvc'; Platform = 'Win32'; HostExtension = '.dll'; ExeExtension = '.exe' }
    'linux-x64'   = @{ Triple = 'x86_64-unknown-linux-gnu'; Platform = 'X11'; HostExtension = '.so'; ExeExtension = '' }
    'linux-arm64' = @{ Triple = 'aarch64-unknown-linux-gnu'; Platform = 'X11'; HostExtension = '.so'; ExeExtension = '' }
    'osx-x64'     = @{ Triple = 'x86_64-apple-darwin'; Platform = 'OSX'; HostExtension = '.dylib'; ExeExtension = '' }
    'osx-arm64'   = @{ Triple = 'aarch64-apple-darwin'; Platform = 'OSX'; HostExtension = '.dylib'; ExeExtension = '' }
}
$script:PathFields = @(
    'presentationProject', 'viewModelIr', 'generatedAdaptersDirectory',
    'generatedRegistryFile', 'generatedRustFile', 'generatedContractFile',
    'cargoManifest', 'outputDirectory'
)
$script:Required = @('version') + $script:PathFields[0..6] + @('packageName', 'rid', 'configuration', 'outputDirectory')

function Invoke-Logged {
    param([Parameter(Mandatory)][string[]]$Command, [string]$WorkingDirectory)
    Write-Host "==> $($Command -join ' ')"
    $exe = $Command[0]
    $args = @()
    if ($Command.Length -gt 1) { $args = $Command[1..($Command.Length - 1)] }
    if ($WorkingDirectory) {
        Push-Location $WorkingDirectory
        try { & $exe @args }
        finally { Pop-Location }
    }
    else {
        & $exe @args
    }
}

function Resolve-ManifestPath {
    param($ManifestDirectory, [string]$Value)
    if ([System.IO.Path]::IsPathRooted($Value)) { return [System.IO.Path]::GetFullPath($Value) }
    return [System.IO.Path]::GetFullPath((Join-Path $ManifestDirectory $Value))
}

function Read-ConsumerManifest {
    param([string]$ManifestPath)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Invalid consumer manifest: manifest does not exist: $ManifestPath"
    }
    $document = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($document -isnot [hashtable]) { throw 'Invalid consumer manifest: the document must be an object' }
    $unknown = @($document.Keys | Where-Object { $_ -notin ($script:Required + @('binary')) })
    if ($unknown.Count -gt 0) { throw "Invalid consumer manifest: unknown field(s): $($unknown -join ', ')" }
    $missing = @($script:Required | Where-Object { -not $document.ContainsKey($_) })
    if ($missing.Count -gt 0) { throw "Invalid consumer manifest: missing required field(s): $($missing -join ', ')" }
    if ([int]$document.version -ne 1) { throw 'Invalid consumer manifest: version must be 1' }
    foreach ($field in $script:PathFields) {
        if ([string]::IsNullOrWhiteSpace([string]$document[$field])) { throw "Invalid consumer manifest: $field must be a non-empty string" }
    }
    if (-not $script:RidTargets.ContainsKey([string]$document.rid)) {
        throw "Invalid consumer manifest: rid must be one of: $(($script:RidTargets.Keys | Sort-Object) -join ', ')"
    }
    if ($document.configuration -notin @('Debug', 'Release')) { throw 'Invalid consumer manifest: configuration must be Debug or Release' }
    foreach ($field in @('packageName', 'binary')) {
        if ($document.ContainsKey($field) -and $document[$field] -and [string]$document[$field] -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
            throw "Invalid consumer manifest: $field must be a Cargo package/binary name"
        }
    }
    if (-not $document.ContainsKey('binary') -or [string]::IsNullOrWhiteSpace([string]$document.binary)) {
        $document.binary = $document.packageName
    }
    $manifestDirectory = Split-Path -Parent $ManifestPath
    $paths = @{}
    foreach ($field in $script:PathFields) {
        $paths[$field] = Resolve-ManifestPath $manifestDirectory ([string]$document[$field])
    }
    foreach ($field in @('presentationProject', 'viewModelIr', 'cargoManifest')) {
        if (-not (Test-Path -LiteralPath $paths[$field] -PathType Leaf)) {
            throw "Invalid consumer manifest: $field does not exist: $($paths[$field])"
        }
    }
    $document._paths = $paths
    $document._manifestDirectory = $manifestDirectory
    return $document
}

function Set-WindowsStaticCrt {
    param([string]$Triple)
    if (-not $Triple.EndsWith('-pc-windows-msvc')) { return }
    $key = "CARGO_TARGET_$($Triple.ToUpperInvariant().Replace('-', '_'))_RUSTFLAGS"
    $required = '-C target-feature=+crt-static'
    $current = [Environment]::GetEnvironmentVariable($key, 'Process')
    if ([string]::IsNullOrWhiteSpace($current)) { $current = '' }
    if ($current -notlike "*$required*") {
        [Environment]::SetEnvironmentVariable($key, "$($current.Trim()) $required".Trim(), 'Process')
    }
}

function Write-Checksums {
    param([string]$Bundle)
    $lines = @(
        Get-ChildItem -LiteralPath $Bundle -File |
            Where-Object { $_.Name -ne 'checksums.sha256' } |
            Sort-Object Name |
            ForEach-Object {
                $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                "$hash *$($_.Name)"
            }
    )
    [System.IO.File]::WriteAllLines((Join-Path $Bundle 'checksums.sha256'), $lines, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-ConsumerPackage {
    param([string]$ProducerRootPath, $Document)
    $paths = $Document._paths
    $rid = [string]$Document.rid
    $target = $script:RidTargets[$rid]
    $hostProject = Join-Path (Resolve-Path $RustoloniaRoot).Path 'host' 'Avalonia.Host.csproj'
    $projectionTool = Join-Path (Resolve-Path $RustoloniaRoot).Path 'projection' 'Avalonia.ViewModelProjection.Tool' 'Avalonia.ViewModelProjection.Tool.csproj'
    $licenseFile = Join-Path $ProducerRootPath 'licence.md'
    foreach ($pair in @(
            @{ Path = $hostProject; Name = 'Avalonia.Host project' },
            @{ Path = $projectionTool; Name = 'view-model projection tool' },
            @{ Path = $licenseFile; Name = 'licence' }
        )) {
        if (-not (Test-Path -LiteralPath $pair.Path -PathType Leaf)) {
            throw "Producer root is invalid; missing $($pair.Name): $($pair.Path)"
        }
    }

    foreach ($field in @('generatedAdaptersDirectory', 'generatedRegistryFile', 'generatedRustFile', 'generatedContractFile')) {
        $parent = Split-Path -Parent $paths[$field]
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    }

    if (-not $SkipGenerate) {
        Invoke-Logged -WorkingDirectory $ProducerRootPath -Command @(
            'dotnet', 'run', '--project', $projectionTool, '-c', [string]$Document.configuration, '--',
            $paths.viewModelIr, $paths.generatedAdaptersDirectory, (Split-Path -Parent $paths.generatedRegistryFile),
            $paths.generatedRustFile, $paths.generatedContractFile, '--external-rust'
        )
    }

    Invoke-Logged -Command @('cargo', 'fmt', '--manifest-path', $paths.cargoManifest)
    Invoke-Logged -Command @(
        'dotnet', 'build', $paths.presentationProject, '-c', [string]$Document.configuration,
        "-p:AvaloniaProducerRoot=$ProducerRootPath"
    )

    $cargoTarget = Join-Path $Document._manifestDirectory '.avalonia' 'cargo-target'
    $previousCargo = [Environment]::GetEnvironmentVariable('CARGO_TARGET_DIR', 'Process')
    [Environment]::SetEnvironmentVariable('CARGO_TARGET_DIR', $cargoTarget, 'Process')
    Set-WindowsStaticCrt $target.Triple
    try {
        $cargoArgs = @(
            'cargo', 'build', '--manifest-path', $paths.cargoManifest, '-p', [string]$Document.packageName,
            '--bin', [string]$Document.binary, '--target', $target.Triple
        )
        $profile = 'debug'
        if ($Document.configuration -eq 'Release') {
            $cargoArgs += '--release'
            $profile = 'release'
        }
        Invoke-Logged -Command $cargoArgs
    }
    finally {
        [Environment]::SetEnvironmentVariable('CARGO_TARGET_DIR', $previousCargo, 'Process')
    }
    $executable = Join-Path $cargoTarget $target.Triple $profile "$($Document.binary)$($target.ExeExtension)"
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Cargo did not produce the declared binary: $executable"
    }

    $bundle = $paths.outputDirectory
    $staging = Join-Path (Split-Path -Parent $bundle) ".$([IO.Path]::GetFileName($bundle)).avalonia-staging"
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        Invoke-Logged -WorkingDirectory $ProducerRootPath -Command @(
            'dotnet', 'publish', $hostProject, '-c', [string]$Document.configuration, '-r', $rid,
            "-p:AvaloniaProducerRoot=$ProducerRootPath",
            "-p:AvaloniaRustHostPlatform=$($target.Platform)",
            "-p:AvaloniaRustPresentationProjects=$($paths.presentationProject)",
            "-p:AvaloniaRustViewRegistryFile=$($paths.generatedRegistryFile)",
            "-p:PublishDir=$staging"
        )
        $hostFile = Join-Path $staging "Avalonia.Host$($target.HostExtension)"
        if (-not (Test-Path -LiteralPath $hostFile -PathType Leaf)) {
            throw "NativeAOT host was not produced: $hostFile"
        }
        if (Test-Path -LiteralPath $bundle) { Remove-Item -LiteralPath $bundle -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $bundle | Out-Null
        Copy-Item -LiteralPath $hostFile -Destination (Join-Path $bundle (Split-Path -Leaf $hostFile))
        $copyExtension = if ($target.HostExtension -eq '.dll') { '.dll' } else { $target.HostExtension }
        Get-ChildItem -LiteralPath $staging -File -Filter "*$copyExtension" | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $bundle $_.Name)
        }
        Copy-Item -LiteralPath $executable -Destination (Join-Path $bundle (Split-Path -Leaf $executable))
        Copy-Item -LiteralPath $licenseFile -Destination (Join-Path $bundle 'licence.md')

        if ($env:AVALONIA_RUST_SIGN_COMMAND) {
            if (-not (Test-Path -LiteralPath $env:AVALONIA_RUST_SIGN_COMMAND -PathType Leaf)) {
                throw 'AVALONIA_RUST_SIGN_COMMAND must name a trusted signing wrapper file'
            }
            Get-ChildItem -LiteralPath $bundle -File |
                Where-Object { $_.Extension -in @('.dll', '.exe', '.so', '.dylib') } |
                ForEach-Object { Invoke-Logged -Command @($env:AVALONIA_RUST_SIGN_COMMAND, $_.FullName) }
        }

        & (Join-Path $PSScriptRoot 'generate-sbom.ps1') -Rid $rid -Bundle $bundle
        Write-Checksums $bundle
    }
    finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
    Write-Host "Package layout ready at $bundle"
}

$producer = (Resolve-Path -LiteralPath $ProducerRoot).Path
$manifestPath = (Resolve-Path -LiteralPath $Manifest).Path
$document = Read-ConsumerManifest $manifestPath
Invoke-ConsumerPackage $producer $document
