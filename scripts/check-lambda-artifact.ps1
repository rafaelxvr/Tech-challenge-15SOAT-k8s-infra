[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Sha256Hex,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Sha256Base64,

    [string]$ArtifactPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Sha256Hex -notmatch '^[0-9a-fA-F]{64}$') {
    throw 'Artifact SHA-256 hex digest must contain exactly 64 hexadecimal characters.'
}

try {
    $bytes = [Convert]::FromBase64String($Sha256Base64)
}
catch {
    throw 'Artifact SHA-256 base64 digest is invalid.'
}

if ($bytes.Length -ne 32) {
    throw 'Artifact SHA-256 base64 digest must decode to 32 bytes.'
}

$derivedHex = ([BitConverter]::ToString($bytes).Replace('-', '')).ToLowerInvariant()
if (-not [string]::Equals($Sha256Hex, $derivedHex, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Artifact SHA-256 hex and base64 values do not represent the same digest.'
}

if (-not [string]::IsNullOrWhiteSpace($ArtifactPath)) {
    if (-not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)) {
        throw 'ArtifactPath does not identify a reviewed JAR file.'
    }
    $actualHex = (Get-FileHash -Algorithm SHA256 -LiteralPath $ArtifactPath).Hash.ToLowerInvariant()
    if ($actualHex -ne $derivedHex) {
        throw 'Artifact file SHA-256 does not match the reviewed digest.'
    }
}

Write-Output "Artifact SHA-256 pair verified: $derivedHex"
