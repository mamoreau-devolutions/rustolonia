#!/usr/bin/env pwsh
#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$RunNativeSmoke
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$MessagePattern)
    $failure = $null
    try { & $Action | Out-Null }
    catch { $failure = $_ }
    Assert-True ($null -ne $failure) "Expected an error matching '$MessagePattern'."
    Assert-True ($failure.Exception.Message -match $MessagePattern) "Unexpected error: $($failure.Exception.Message)"
}

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'rust' 'package-shared.ps1')

function Test-NativeConsumer {
    param([string]$Scratch)

    if ($IsLinux -and [string]::IsNullOrWhiteSpace($env:DISPLAY)) {
        throw 'Native Linux smoke execution requires a display. Run this script with xvfb-run -a pwsh -NoProfile -File ... -RunNativeSmoke.'
    }

    $architecture = Get-CurrentRuntimeArchitecture
    $platform = if ($IsWindows) { 'win' } elseif ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'osx' } else { throw 'Unsupported native smoke platform.' }
    $rid = "$platform-$architecture"
    $target = Get-RidTargetInfo -Rid $rid
    $producer = Join-Path $root 'avalonia-src'
    $consumer = Join-Path $Scratch 'native consumer'
    & (Join-Path $root 'rust' 'new-app.ps1') -Name smoke_app -Destination $consumer -ProducerRoot $producer -RustoloniaRoot $root
    $manifestPath = Join-Path $consumer 'avalonia-app.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    $manifest.rid = $rid
    $manifest.configuration = 'Release'
    $manifest.outputDirectory = "artifacts/$rid"
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8

    $previousSigner = $env:AVALONIA_RUST_SIGN_COMMAND
    try {
        Remove-Item Env:AVALONIA_RUST_SIGN_COMMAND -ErrorAction SilentlyContinue
        & (Join-Path $root 'rust' 'build-app.ps1') -ProducerRoot $producer -Manifest $manifestPath
    }
    finally {
        if ($null -ne $previousSigner) { $env:AVALONIA_RUST_SIGN_COMMAND = $previousSigner }
        else { Remove-Item Env:AVALONIA_RUST_SIGN_COMMAND -ErrorAction SilentlyContinue }
    }

    $bundle = Join-Path $consumer 'artifacts' $rid
    $executable = Join-Path $bundle "smoke_app$($target.ExeExtension)"
    Assert-True (Test-Path -LiteralPath $executable -PathType Leaf) "Packaged executable is missing: $executable"
    Assert-True (Test-Path -LiteralPath (Join-Path $bundle "Avalonia.Host$($target.HostExtension)") -PathType Leaf) 'Packaged host is missing.'
    $inventory = Get-Content -LiteralPath (Join-Path $bundle 'sbom.cdx.json') -Raw | ConvertFrom-Json
    Assert-True (@($inventory.components | Where-Object { $_.type -eq 'library' -and $_.purl -like 'pkg:nuget/*' }).Count -gt 0) 'Packaged inventory must contain the published host dependencies.'
    foreach ($line in Get-Content -LiteralPath (Join-Path $bundle 'checksums.sha256')) {
        $expected, $file = $line -split '\s+\*', 2
        $actual = (Get-FileHash -LiteralPath (Join-Path $bundle $file) -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-True ($actual -eq $expected) "Checksum mismatch for $file"
    }

    $previousHost = $env:AVN_HOST_NATIVE_LIB
    $process = $null
    try {
        Remove-Item Env:AVN_HOST_NATIVE_LIB -ErrorAction SilentlyContinue
        $process = Start-Process -FilePath $executable -WorkingDirectory $bundle -PassThru
        Assert-True (-not $process.WaitForExit(5000)) "Packaged consumer exited during startup."
    }
    finally {
        if ($null -ne $previousHost) { $env:AVN_HOST_NATIVE_LIB = $previousHost }
        else { Remove-Item Env:AVN_HOST_NATIVE_LIB -ErrorAction SilentlyContinue }
        if ($null -ne $process) {
            try {
                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id
                    Assert-True ($process.WaitForExit(10000)) 'Packaged consumer did not stop.'
                }
            }
            finally { $process.Dispose() }
        }
    }
    Write-Host "Native consumer smoke passed for $rid."
}

$scratch = Join-Path $root 'rust' 'target' ('test-build-app-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $productionScripts = Get-ChildItem -LiteralPath (Join-Path $root 'rust'), (Join-Path $root 'avalonia-patches') -Filter '*.ps1' -File
    foreach ($scriptFile in $productionScripts) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
        $messages = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
        Assert-True ($parseErrors.Count -eq 0) "Invalid script $($scriptFile.FullName): $messages"
    }

    $publishProperties = @('-p:AvaloniaProducerRoot=producer path', '-p:RustoloniaRoot=rustolonia path')
    $publishCommand = New-DotnetPublishCommand -Project 'host project.csproj' -Configuration Release -Rid win-x64 -ArtifactsPath 'artifacts path' -AdditionalProperties $publishProperties
    Assert-True ($publishCommand[0] -eq 'dotnet' -and $publishCommand[2] -eq 'host project.csproj') 'Publish argv must preserve command and spaced paths.'
    Assert-True ($publishCommand[-1] -eq $publishProperties[-1]) 'Publish argv must include the final override.'
    & {
        $assetsDirectory = Join-Path $scratch 'custom artifacts' 'obj' 'Avalonia.Host'
        New-Item -ItemType Directory -Force -Path $assetsDirectory | Out-Null
        $assetsFile = Join-Path $assetsDirectory 'project.assets.json'
        Set-Content -LiteralPath $assetsFile -Value '{"libraries":{}}'
        function dotnet {
            Assert-True ($args[0] -eq 'msbuild' -and $args -contains '-getProperty:ProjectAssetsFile') 'Restore metadata must be queried from MSBuild.'
            Assert-True ($args -contains '-p:Configuration=Release' -and $args -contains '-p:RuntimeIdentifier=win-x64') 'Metadata evaluation must match publish configuration and RID.'
            Assert-True ($args -contains '-p:AvaloniaProducerRoot=producer path' -and $args -contains '-p:RustoloniaRoot=rustolonia path') 'Metadata evaluation must preserve publish overrides.'
            Assert-True (($args -contains "-p:ArtifactsPath=$(Resolve-CallerRelativePath -PathValue 'artifacts path')") -eq $expectArtifacts) 'Metadata evaluation must preserve the optional artifacts path.'
            $global:LASTEXITCODE = 0
            $assetsFile
        }
        $expectArtifacts = $true
        $resolvedAssets = Get-PublishedProjectAssetsFile -Project 'host project.csproj' -Configuration Release -Rid win-x64 -ArtifactsPath 'artifacts path' -AdditionalProperties $publishProperties
        Assert-True ($resolvedAssets -eq $assetsFile) 'Metadata must come from the evaluated path, not host/obj.'
        $expectArtifacts = $false
        $resolvedAssets = Get-PublishedProjectAssetsFile -Project 'host project.csproj' -Configuration Release -Rid win-x64 -AdditionalProperties $publishProperties
        Assert-True ($resolvedAssets -eq $assetsFile) 'Consumer publication must also query its restore metadata.'
        $assetsFile = Join-Path $scratch 'missing.assets.json'
        Assert-Throws { Get-PublishedProjectAssetsFile -Project 'host project.csproj' -Configuration Release -Rid win-x64 -AdditionalProperties $publishProperties } 'metadata does not exist'
        $assetsFile = ''
        Assert-Throws { Get-PublishedProjectAssetsFile -Project 'host project.csproj' -Configuration Release -Rid win-x64 -AdditionalProperties $publishProperties } 'ProjectAssetsFile was empty'
    }
    $cargoCommand = New-CargoBuildCommand -ManifestPath 'app path/Cargo.toml' -PackageName example_app -TargetTriple x86_64-pc-windows-msvc -Example hello_world
    Assert-True ($cargoCommand.Count -eq 11 -and $cargoCommand[0] -eq 'cargo' -and $cargoCommand[3] -eq 'app path/Cargo.toml') 'Cargo argv must be flat and preserve spaced paths.'

    $hostProperties = New-HostPublishProperties -ProducerRoot producer -RustoloniaRoot rustolonia -Rid win-x64 -HostPlatform Win32
    Assert-True ($hostProperties -contains '-p:AvaloniaProducerRoot=producer') 'Host publish must use the declared producer.'
    Assert-True (@($hostProperties | Where-Object { $_ -like '-p:ObjCopyName=*' }).Count -eq 0) 'Windows publish must not set objcopy.'
    $linuxProperties = New-HostPublishProperties -ProducerRoot producer -RustoloniaRoot rustolonia -Rid linux-arm64 -HostPlatform X11 -CurrentArchitecture x64 -ObjCopyName aarch64-linux-gnu-objcopy
    Assert-True ($linuxProperties -contains '-p:ObjCopyName=aarch64-linux-gnu-objcopy') 'Linux publish must pass its cross objcopy.'
    & {
        $availableTools = @('aarch64-linux-gnu-objcopy', 'x86_64-linux-gnu-objcopy')
        function Get-Command {
            [CmdletBinding()]
            param([string]$Name)
            if ($Name -in $availableTools) { [pscustomobject]@{ Name = $Name } }
        }
        Assert-True ((Resolve-LinuxCrossObjCopyName -Rid linux-arm64 -CurrentArchitecture x64) -eq $availableTools[0]) 'ARM64 cross tool selection is incorrect.'
        Assert-True ((Resolve-LinuxCrossObjCopyName -Rid linux-x64 -CurrentArchitecture arm64) -eq $availableTools[1]) 'x64 cross tool selection is incorrect.'
        Assert-True ($null -eq (Resolve-LinuxCrossObjCopyName -Rid linux-x64 -CurrentArchitecture x64)) 'Native Linux builds must not need a cross tool.'
        $availableTools = @()
        Assert-Throws { Resolve-LinuxCrossObjCopyName -Rid linux-x64 -CurrentArchitecture arm64 } 'binutils-x86-64-linux-gnu'
    }

    $fakeProducer = Join-Path $scratch 'fake producer'
    $headerDirectory = Join-Path $fakeProducer 'nukebuild'
    New-Item -ItemType Directory -Force -Path $headerDirectory | Out-Null
    Set-Content -LiteralPath (Join-Path $headerDirectory '_build.csproj') -Value '<Project />'
    $headerCommand = New-ProducerHeaderGenerationCommand -ProducerRoot $fakeProducer
    Assert-True ($headerCommand[-1] -eq 'GenerateCppHeaders') 'Native preparation must generate COM headers.'
    $xcodeProject = Join-Path $fakeProducer 'native' 'Avalonia.Native' 'src' 'OSX' 'Avalonia.Native.OSX.xcodeproj'
    New-Item -ItemType Directory -Force -Path $xcodeProject | Out-Null
    foreach ($configuration in @('Debug', 'Release')) {
        $xcodeCommand = New-XcodeBuildCommand -ProducerRoot $fakeProducer -Rid osx-arm64 -Configuration $configuration
        Assert-True ($xcodeCommand[4] -eq $configuration -and $xcodeCommand -contains 'ARCHS=arm64') 'Xcode must use the requested configuration and architecture.'
        Assert-True ($xcodeCommand -contains "CONFIGURATION_BUILD_DIR=$(Join-Path $fakeProducer 'Build' 'Products' 'Release')") 'Xcode output must match the pinned producer layout.'
    }

    Push-Location $scratch
    try {
        Assert-True ((Resolve-CallerRelativePath -PathValue 'relative-output') -eq (Join-Path $scratch 'relative-output')) 'Output paths must follow the caller location.'
        Assert-True ((Resolve-CallerRelativePath -PathValue (Join-Path 'nested' 'output')) -eq (Join-Path $scratch 'nested' 'output')) 'Nested output paths must follow the caller location.'
    }
    finally { Pop-Location }

    $firstStaging = New-IsolatedPackageStagingRoot -OutputRoot $scratch -Rid win-x64
    $secondStaging = New-IsolatedPackageStagingRoot -OutputRoot $scratch -Rid win-x64
    Assert-True ($firstStaging -ne $secondStaging -and (Test-Path -LiteralPath $firstStaging) -and (Test-Path -LiteralPath $secondStaging)) 'Staging must not remove another active invocation.'
    $sourceBundle = Join-Path $scratch 'source-bundle'
    New-Item -ItemType Directory -Path $sourceBundle | Out-Null
    $sourceHost = Join-Path $sourceBundle 'Avalonia.Host.dll'
    Set-Content -LiteralPath $sourceHost -Value 'stub host'
    Set-Content -LiteralPath (Join-Path $sourceBundle 'libexample.so.1') -Value 'versioned native library'
    $copyBundle = Join-Path $scratch 'source-bundle-copy'
    Prepare-ArtifactBundle -BundlePath $copyBundle | Out-Null
    $metadata = Join-Path $copyBundle 'metadata.txt'
    Set-Content -LiteralPath $metadata -Value 'preserve me'
    Copy-BundleFiles -SourceDirectory $sourceBundle -DestinationDirectory $copyBundle -HostFile $sourceHost -Rid win-x64
    Assert-True ((Get-Content -LiteralPath $metadata -Raw).Trim() -eq 'preserve me') 'Copying must preserve existing metadata.'
    Assert-True (Test-Path -LiteralPath (Join-Path $copyBundle 'libexample.so.1')) 'Versioned native libraries must be copied.'
    Assert-Throws { Copy-BundleFiles -SourceDirectory $sourceBundle -DestinationDirectory $sourceBundle -HostFile $sourceHost -Rid win-x64 } 'differ|overlap|nested'
    $protectedBundle = Join-Path $scratch 'protected-bundle'
    New-Item -ItemType Directory -Path $protectedBundle | Out-Null
    Set-Content -LiteralPath (Join-Path $protectedBundle 'user.data') -Value 'preserve me'
    Assert-Throws { Prepare-ArtifactBundle -BundlePath $protectedBundle } 'Refusing'
    Assert-True (Test-Path -LiteralPath (Join-Path $protectedBundle 'user.data')) 'Refused output must preserve user data.'

    $signingRoot = Join-Path $scratch 'signing'
    New-Item -ItemType Directory -Path $signingRoot | Out-Null
    $extensionlessApp = Join-Path $signingRoot 'app'
    Set-Content -LiteralPath $extensionlessApp -Value 'app'
    Set-Content -LiteralPath (Join-Path $signingRoot 'LICENSE') -Value 'license'
    Set-Content -LiteralPath (Join-Path $signingRoot '.rustolonia-bundle-owner') -Value 'marker'
    $signerScript = Join-Path $scratch 'fake-sign.ps1'
    $signLog = Join-Path $scratch 'signatures.log'
    @'
param([Parameter(Mandatory, Position = 0)][string]$ArtifactPath)
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'signatures.log') -Value $ArtifactPath
'@ | Set-Content -LiteralPath $signerScript
    Invoke-ArtifactSigning -ArtifactDirectory $signingRoot -SignCommand $signerScript -ExplicitFiles @($extensionlessApp)
    $signed = @(Get-Content -LiteralPath $signLog)
    Assert-True ($signed.Count -eq 1 -and $signed[0] -eq $extensionlessApp) 'An explicit extensionless app must be signable without any native-library matches.'
    $nativeLibrary = Join-Path $signingRoot 'libexample.so.1'
    Set-Content -LiteralPath $nativeLibrary -Value 'library'
    Invoke-ArtifactSigning -ArtifactDirectory $signingRoot -SignCommand $signerScript -ExplicitFiles @($extensionlessApp)
    $signed = @(Get-Content -LiteralPath $signLog)
    Assert-True ($signed -contains $nativeLibrary -and $signed.Count -eq 3) 'Signing must include native libraries, not LICENSE or owner markers.'
    Assert-Throws { Invoke-ArtifactSigning -ArtifactDirectory $signingRoot -SignCommand $signerScript -ExplicitFiles @('missing-app') } 'missing'
    Assert-True (@(Get-Content -LiteralPath $signLog).Count -eq 3) 'Missing signing inputs must fail before signing anything.'

    $consumer = Join-Path $scratch 'external app directory' 'My App'
    $scriptOutput = & (Join-Path $root 'rust' 'new-app.ps1') -Name demo_app -Destination $consumer -ProducerRoot $fakeProducer -RustoloniaRoot $root 6>&1
    $scriptText = $scriptOutput | Out-String
    $rustoloniaPath = $root.Replace('\', '/')
    $producerPath = $fakeProducer.Replace('\', '/')
    $manifestPath = (Join-Path $consumer 'avalonia-app.json').Replace('\', '/')
    $expectedCommand = "pwsh `"$rustoloniaPath/rust/build-app.ps1`" -ProducerRoot `"$producerPath`" -Manifest `"$manifestPath`""
    Assert-True ($scriptText.Contains($expectedCommand)) 'Printed build arguments must preserve exact spaced paths.'
    $cargoText = Get-Content -LiteralPath (Join-Path $consumer 'Cargo.toml') -Raw
    Assert-True ($cargoText.Contains("path = `"$rustoloniaPath/rust/avalonia`"")) 'Cargo must reference Rustolonia rather than the producer.'
    $projectText = Get-Content -LiteralPath (Join-Path $consumer 'managed' 'Consumer.Presentation.csproj') -Raw
    Assert-True ($projectText.Contains($producerPath) -and $projectText.Contains($rustoloniaPath) -and -not $projectText.Contains('__AVALONIA_PRODUCER_ROOT__')) 'Presentation roots must be substituted.'
    Assert-Throws { & (Join-Path $root 'rust' 'new-app.ps1') -Name demo_app -Destination $consumer -ProducerRoot $fakeProducer -RustoloniaRoot $root } 'already exists'
    $invalidDestination = Join-Path $scratch 'invalid-consumer'
    Assert-Throws { & (Join-Path $root 'rust' 'new-app.ps1') -Name demo_app -Destination $invalidDestination -ProducerRoot (Join-Path $scratch 'missing-producer') -RustoloniaRoot $root } 'does not exist'
    Assert-True (-not (Test-Path -LiteralPath $invalidDestination)) 'Invalid roots must not create an output directory.'
    Push-Location $scratch
    try {
        & (Join-Path $root 'rust' 'new-app.ps1') -Name relative_app -Destination 'relative app' -ProducerRoot $fakeProducer -RustoloniaRoot $root | Out-Null
        Assert-True (Test-Path -LiteralPath (Join-Path $scratch 'relative app' 'Cargo.toml')) 'Relative scaffolds must use the caller location.'
    }
    finally { Pop-Location }

    $badManifest = Get-Content -LiteralPath (Join-Path $consumer 'avalonia-app.json') -Raw | ConvertFrom-Json -AsHashtable
    $badManifest.unexpected = $true
    $badManifestPath = Join-Path $consumer 'bad.json'
    $badManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $badManifestPath
    Assert-Throws { & (Join-Path $root 'rust' 'build-app.ps1') -ProducerRoot $fakeProducer -Manifest $badManifestPath } 'unknown field'
    $invalidFields = @(
        @{ Field = 'version'; Value = '1' },
        @{ Field = 'version'; Value = '2026-01-01T00:00:00Z' },
        @{ Field = 'version'; Value = $true },
        @{ Field = 'version'; Value = 1.4 },
        @{ Field = 'version'; Value = $null },
        @{ Field = 'version'; Value = @(1) },
        @{ Field = 'packageName'; Value = '' },
        @{ Field = 'packageName'; Value = $null },
        @{ Field = 'packageName'; Value = 123 },
        @{ Field = 'binary'; Value = '' },
        @{ Field = 'binary'; Value = $null },
        @{ Field = 'binary'; Value = @('demo_app') },
        @{ Field = 'rid'; Value = 'WIN-X64' },
        @{ Field = 'rid'; Value = @('win-x64') },
        @{ Field = 'configuration'; Value = 'release' },
        @{ Field = 'configuration'; Value = @('Release') }
    )
    foreach ($field in @('presentationProject', 'viewModelIr', 'generatedAdaptersDirectory', 'generatedRegistryFile', 'generatedRustFile', 'generatedContractFile', 'cargoManifest', 'outputDirectory')) {
        foreach ($value in @($null, '', 123, @('path'), @{ path = 'value' })) {
            $invalidFields += @{ Field = $field; Value = $value }
        }
    }
    foreach ($case in $invalidFields) {
        $badManifest = Get-Content -LiteralPath (Join-Path $consumer 'avalonia-app.json') -Raw | ConvertFrom-Json -AsHashtable
        $badManifest[$case.Field] = $case.Value
        $badManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $badManifestPath
        Assert-Throws { & (Join-Path $root 'rust' 'build-app.ps1') -ProducerRoot $fakeProducer -Manifest $badManifestPath } "Invalid consumer manifest: $($case.Field)"
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $consumer '.avalonia'))) 'Invalid manifests must not create build outputs.'

    $inventory = Join-Path $scratch 'inventory'
    New-Item -ItemType Directory -Path $inventory | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $inventory 'z.bin'), [byte[]](0x7A))
    [IO.File]::WriteAllBytes((Join-Path $inventory 'a.bin'), [byte[]](0x61))
    Set-Content -LiteralPath (Join-Path $inventory '.hidden-metadata') -Value 'inventory metadata'
    & (Join-Path $root 'rust' 'generate-sbom.ps1') -Rid win-x64 -Bundle $inventory
    $first = [IO.File]::ReadAllBytes((Join-Path $inventory 'sbom.cdx.json'))
    & (Join-Path $root 'rust' 'generate-sbom.ps1') -Rid win-x64 -Bundle $inventory
    $second = [IO.File]::ReadAllBytes((Join-Path $inventory 'sbom.cdx.json'))
    Assert-True ([Linq.Enumerable]::SequenceEqual($first, $second)) 'Delivery inventory must be repeatable.'
    $sbom = Get-Content -LiteralPath (Join-Path $inventory 'sbom.cdx.json') -Raw | ConvertFrom-Json
    Assert-True ($sbom.components.name -contains '.hidden-metadata') 'Delivery inventory must include hidden metadata on every OS.'
    Write-Checksums -Bundle $inventory
    Assert-True (@(Get-Content -LiteralPath (Join-Path $inventory 'checksums.sha256') | Where-Object { $_.EndsWith('*.hidden-metadata') }).Count -eq 1) 'Checksums must include hidden metadata on every OS.'

    $depsInventory = Join-Path $scratch 'deps-inventory'
    New-Item -ItemType Directory -Path $depsInventory | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $depsInventory 'a.bin'), [byte[]](0x61))
    $fakeAssets = Join-Path $scratch 'project.assets.json'
    Set-Content -LiteralPath $fakeAssets -Value '{"libraries":{"Some.Package/1.2.3":{"type":"package"},"local-project/1.0.0":{"type":"project"}}}'
    $fakeCargoLock = Join-Path $scratch 'Cargo.lock'
    Set-Content -LiteralPath $fakeCargoLock -Value @'
[[package]]
name = "third-party-crate"
version = "0.4.1"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "avalonia"
version = "0.1.0"
'@
    & (Join-Path $root 'rust' 'generate-sbom.ps1') -Rid win-x64 -Bundle $depsInventory -CargoLockPath $fakeCargoLock -ProjectAssetsJsonPath $fakeAssets -ProducerPin 'deadbeef'
    $depsSbom = Get-Content -LiteralPath (Join-Path $depsInventory 'sbom.cdx.json') -Raw | ConvertFrom-Json
    Assert-True (@($depsSbom.components | Where-Object { $_.type -eq 'library' -and $_.purl -eq 'pkg:nuget/Some.Package@1.2.3' }).Count -eq 1) 'SBOM must include resolved NuGet package dependencies.'
    Assert-True (@($depsSbom.components | Where-Object { $_.type -eq 'library' -and $_.name -eq 'local-project' }).Count -eq 0) 'SBOM must not list local project references as third-party dependencies.'
    Assert-True (@($depsSbom.components | Where-Object { $_.type -eq 'library' -and $_.purl -eq 'pkg:cargo/third-party-crate@0.4.1' }).Count -eq 1) 'SBOM must include resolved Cargo dependencies.'
    Assert-True (@($depsSbom.components | Where-Object { $_.type -eq 'library' -and $_.name -eq 'avalonia' -and $_.version -eq '0.1.0' }).Count -eq 0) 'SBOM must not list workspace-local crates without a [source] as third-party dependencies.'
    Assert-True (@($depsSbom.metadata.properties | Where-Object { $_.name -eq 'avalonia:producer-pin' -and $_.value -eq 'deadbeef' }).Count -eq 1) 'SBOM must record the producer pin used to build the bundle.'
    & (Join-Path $root 'rust' 'generate-sbom.ps1') -Rid win-x64 -Bundle $depsInventory -CargoLockPath (Join-Path $scratch 'missing.lock') -ProjectAssetsJsonPath (Join-Path $scratch 'missing.assets.json')
    $missingSbom = Get-Content -LiteralPath (Join-Path $depsInventory 'sbom.cdx.json') -Raw | ConvertFrom-Json
    foreach ($ecosystem in @('nuget', 'cargo')) {
        $source = @($missingSbom.metadata.properties | Where-Object { $_.name -eq "avalonia:$ecosystem-dependency-source" })
        Assert-True ($source.Count -eq 1 -and $source[0].value -like 'unavailable:*does not exist') 'Missing supplied dependency files must not be reported as available.'
    }

    if ($RunNativeSmoke) { Test-NativeConsumer -Scratch $scratch }
}
finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

Write-Host 'Helper and scaffold regressions passed.'
