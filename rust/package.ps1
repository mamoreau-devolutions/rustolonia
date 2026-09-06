#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
Package the NativeAOT host and a Rust example for one RID.
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet('win-x64', 'win-arm64', 'linux-x64', 'linux-arm64', 'osx-x64', 'osx-arm64')]
    [string]$Rid,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$Example = 'hello_world',
    [string]$OutputRoot,
    [switch]$SkipCargoBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# rust/<script> -> the Avalonia repository root is three levels up
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$avaloniaRoot = Join-Path $repositoryRoot 'avalonia-src'
$ridMap = @{
    'win-x64'     = @{ Triple = 'x86_64-pc-windows-msvc'; Platform = 'Win32'; HostExtension = '.dll'; ExeExtension = '.exe'; OS = 'Windows' }
    'win-arm64'   = @{ Triple = 'aarch64-pc-windows-msvc'; Platform = 'Win32'; HostExtension = '.dll'; ExeExtension = '.exe'; OS = 'Windows' }
    'linux-x64'   = @{ Triple = 'x86_64-unknown-linux-gnu'; Platform = 'X11'; HostExtension = '.so'; ExeExtension = ''; OS = 'Linux' }
    'linux-arm64' = @{ Triple = 'aarch64-unknown-linux-gnu'; Platform = 'X11'; HostExtension = '.so'; ExeExtension = ''; OS = 'Linux' }
    'osx-x64'     = @{ Triple = 'x86_64-apple-darwin'; Platform = 'OSX'; HostExtension = '.dylib'; ExeExtension = ''; OS = 'macOS' }
    'osx-arm64'   = @{ Triple = 'aarch64-apple-darwin'; Platform = 'OSX'; HostExtension = '.dylib'; ExeExtension = ''; OS = 'macOS' }
}
$spec = $ridMap[$Rid]
$architecture = $Rid.Split('-')[1]
$nativeArchitecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64' { 'x64' }
    'Arm64' { 'arm64' }
    default { throw "Unsupported CPU architecture: $_" }
}

if ($IsWindows -and $spec.OS -ne 'Windows') { throw "$Rid packaging must run on Windows." }
if ($IsLinux -and $spec.OS -ne 'Linux') { throw "$Rid packaging must run on Linux." }
if ($IsMacOS -and $spec.OS -ne 'macOS') { throw "$Rid packaging must run on macOS." }
if ($architecture -ne $nativeArchitecture) {
    # Same-OS cross-architecture packaging (e.g. win-arm64 from an x64 runner) is
    # supported: dotnet publish cross-compiles the NativeAOT host for the target RID
    # and cargo builds for the target triple, neither of which executes the target
    # binaries. Consumers that need to run the packaged sample must do so on matching
    # hardware; the checksums cover the produced artifacts either way.
    Write-Warning "$Rid is being cross-built on a $nativeArchitecture runner. The packaged sample cannot be smoke-launched here."
}

if ($spec.Platform -eq 'X11') {
    $dbus = Join-Path $avaloniaRoot 'external' 'Avalonia.DBus' 'src' 'Avalonia.DBus' 'Avalonia.DBus.csproj'
    if (-not (Test-Path -LiteralPath $dbus -PathType Leaf)) {
        throw 'Initialize Linux sources with: git submodule update --init external/Avalonia.DBus'
    }
}

if ($spec.Platform -eq 'OSX') {
    # Build libAvaloniaNative for the RID's architecture, not the runner's, so
    # cross-architecture packaging (e.g. osx-x64 from an arm64 runner) publishes a
    # matching native library.
    $xcodeArch = if ($architecture -eq 'x64') { 'x86_64' } else { 'arm64' }
    $xcodeProject = Join-Path $avaloniaRoot 'native' 'Avalonia.Native' 'src' 'OSX' 'Avalonia.Native.OSX.xcodeproj'
    $products = Join-Path $avaloniaRoot 'Build' 'Products' 'Release'
    xcodebuild -project $xcodeProject -configuration $Configuration "ARCHS=$xcodeArch" "CONFIGURATION_BUILD_DIR=$products"
}

if (-not $OutputRoot) {
    $OutputRoot = if ($env:AVN_PACKAGE_OUTPUT) { $env:AVN_PACKAGE_OUTPUT } else { Join-Path $PSScriptRoot 'artifacts' }
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$destination = Join-Path $OutputRoot $Rid

if ($spec.Triple.EndsWith('-pc-windows-msvc')) {
    $rustFlagsVariable = "CARGO_TARGET_$($spec.Triple.ToUpperInvariant().Replace('-', '_'))_RUSTFLAGS"
    $rustFlags = [Environment]::GetEnvironmentVariable($rustFlagsVariable, 'Process')
    if ($rustFlags -notlike '*target-feature=+crt-static*') {
        [Environment]::SetEnvironmentVariable($rustFlagsVariable, "$rustFlags -C target-feature=+crt-static".Trim(), 'Process')
    }
}

$installed = rustup target list --installed
if ($installed -notcontains $spec.Triple) {
    throw "Rust target '$($spec.Triple)' required for RID '$Rid' is missing. Install it with: rustup target add $($spec.Triple)"
}

$artifacts = if ($env:AVN_DOTNET_ARTIFACTS) { $env:AVN_DOTNET_ARTIFACTS } else { Join-Path $PSScriptRoot 'target' "dotnet-$Rid" }
$publishProperties = @("-p:AvaloniaRustHostPlatform=$($spec.Platform)")
if ($IsLinux -and $architecture -ne $nativeArchitecture) {
    # NativeAOT strips debug symbols through binutils objcopy; the host's x86
    # objcopy cannot parse arm64 ELF files, so cross-arch Linux packaging points
    # ObjCopyName at the cross toolchain's aarch64-linux-gnu-objcopy.
    $crossObjCopy = "aarch64-linux-gnu-objcopy"
    if (Get-Command $crossObjCopy -ErrorAction SilentlyContinue) {
        $publishProperties += "-p:ObjCopyName=$crossObjCopy"
    }
    else {
        throw "Cross-building $Rid requires $crossObjCopy on PATH. Install it with: sudo apt-get install gcc-aarch64-linux-gnu"
    }
}
Write-Host "==> Publishing Avalonia.Host ($Rid, $Configuration)"
dotnet publish (Join-Path $repositoryRoot 'host' 'Avalonia.Host.csproj') `
    -c $Configuration -r $Rid @publishProperties `
    --artifacts-path $artifacts

$publishDir = Join-Path $artifacts 'publish' 'Avalonia.Host' "$($Configuration.ToLowerInvariant())_$Rid"
$hostFile = Join-Path $publishDir "Avalonia.Host$($spec.HostExtension)"
if (-not (Test-Path -LiteralPath $hostFile -PathType Leaf)) {
    throw "NativeAOT host was not produced at $hostFile"
}

if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Write-Host "==> Copying host and native dependencies into $destination"
Copy-Item -LiteralPath $hostFile -Destination $destination
Get-ChildItem -LiteralPath $publishDir -File | Where-Object {
    $_.FullName -ne $hostFile -and (
        $_.Extension -in @('.dll', '.so', '.dylib') -or $_.Name -like '*.so.*'
    )
} | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $destination }
Copy-Item -LiteralPath (Join-Path $avaloniaRoot 'licence.md') -Destination $destination

if ($spec.Platform -eq 'OSX' -and -not (Test-Path -LiteralPath (Join-Path $destination 'libAvaloniaNative.dylib') -PathType Leaf)) {
    throw 'libAvaloniaNative.dylib was not published with the macOS host.'
}

if (-not $SkipCargoBuild -and -not $env:AVN_PACKAGE_SKIP_CARGO_BUILD) {
    Write-Host "==> Building Rust example '$Example' ($Configuration) next to the host"
    $cargoTarget = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $PSScriptRoot 'target' "cargo-$Rid" }
    $previousCargo = [Environment]::GetEnvironmentVariable('CARGO_TARGET_DIR', 'Process')
    [Environment]::SetEnvironmentVariable('CARGO_TARGET_DIR', $cargoTarget, 'Process')
    try {
        $cargoArgs = @('build', '--manifest-path', (Join-Path $PSScriptRoot 'Cargo.toml'), '-p', 'avalonia', '--example', $Example, '--target', $spec.Triple)
        $profile = 'debug'
        if ($Configuration -eq 'Release') { $cargoArgs += '--release'; $profile = 'release' }
        cargo @cargoArgs
    }
    finally {
        [Environment]::SetEnvironmentVariable('CARGO_TARGET_DIR', $previousCargo, 'Process')
    }
    $exePath = Join-Path $cargoTarget $spec.Triple $profile 'examples' "$Example$($spec.ExeExtension)"
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw "Rust example binary was not produced at $exePath"
    }
    Copy-Item -LiteralPath $exePath -Destination $destination
}

if ($env:AVALONIA_RUST_SIGN_COMMAND) {
    if (-not (Test-Path -LiteralPath $env:AVALONIA_RUST_SIGN_COMMAND -PathType Leaf)) {
        throw 'AVALONIA_RUST_SIGN_COMMAND must be the path to a signing wrapper executable or script.'
    }
    Write-Host '==> Signing executable artifacts with AVALONIA_RUST_SIGN_COMMAND'
    Get-ChildItem -LiteralPath $destination -File | Where-Object {
        $_.Extension -in @('.dll', '.exe', '.so', '.dylib') -or $_.Name -like '*.so.*' -or $_.Name -eq $Example
    } | ForEach-Object {
        Write-Host "    signing $($_.Name)"
        & $env:AVALONIA_RUST_SIGN_COMMAND $_.FullName
    }
}
else {
    Write-Host 'AVALONIA_RUST_SIGN_COMMAND is not set; skipping signing. Set it to a trusted signing wrapper; it receives each artifact path as its only argument. This script never downloads a signing tool.'
}

Write-Host '==> Writing deterministic CycloneDX delivery SBOM'
& (Join-Path $PSScriptRoot 'generate-sbom.ps1') -Rid $Rid -Bundle $destination

Write-Host '==> Writing checksums.sha256'
$checksumPath = Join-Path $destination 'checksums.sha256'
$lines = @(
    Get-ChildItem -LiteralPath $destination -File |
        Where-Object { $_.Name -ne 'checksums.sha256' } |
        Sort-Object Name |
        ForEach-Object {
            $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            "$hash *$($_.Name)"
        }
)
[System.IO.File]::WriteAllLines($checksumPath, $lines, [System.Text.UTF8Encoding]::new($false))

Write-Host "Package layout ready at $destination"
Get-ChildItem -LiteralPath $destination | Select-Object Name, Length | Format-Table -AutoSize
