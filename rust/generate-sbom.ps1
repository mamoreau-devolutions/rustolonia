#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
Writes a deterministic CycloneDX 1.5 delivery SBOM for a packaged Rust bundle.
#>
param(
    [Parameter(Mandatory)][string]$Rid,
    [Parameter(Mandatory)][string]$Bundle
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bundlePath = (Resolve-Path -LiteralPath $Bundle).Path
$output = Join-Path $bundlePath 'sbom.cdx.json'
$ridBytes = [System.Text.Encoding]::UTF8.GetBytes($Rid)
$bundleId = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($ridBytes)).Replace('-', '').ToLowerInvariant()
$serial = "urn:uuid:$($bundleId.Substring(0, 8))-$($bundleId.Substring(8, 4))-5$($bundleId.Substring(12, 3))-8$($bundleId.Substring(15, 3))-$($bundleId.Substring(18, 12))"

$components = @(
    Get-ChildItem -LiteralPath $bundlePath -File |
        Where-Object { $_.Name -notin @('checksums.sha256', 'sbom.cdx.json') } |
        Sort-Object Name |
        ForEach-Object {
            [ordered]@{
                type       = 'file'
                name       = $_.Name
                version    = $Rid
                hashes     = @([ordered]@{ alg = 'SHA-256'; content = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
                properties = @([ordered]@{ name = 'avalonia:delivery-path'; value = $_.Name })
            }
        }
)

$document = [ordered]@{
    bomFormat    = 'CycloneDX'
    specVersion  = '1.5'
    serialNumber = $serial
    version      = 1
    metadata     = [ordered]@{
        component = [ordered]@{ type = 'application'; name = 'Avalonia Rust bundle'; version = $Rid }
    }
    components   = $components
}

$json = $document | ConvertTo-Json -Depth 8
# ConvertTo-Json may emit CRLF; the delivery file is UTF-8 LF.
[System.IO.File]::WriteAllText($output, ($json.Replace("`r`n", "`n") + "`n"))
