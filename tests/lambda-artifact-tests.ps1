[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $repoRoot 'scripts/check-lambda-artifact.ps1'
$hex = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
$base64 = 'ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0='

& $validator -Sha256Hex $hex -Sha256Base64 $base64

$mismatchRejected = $false
try {
    & $validator -Sha256Hex ('0' * 64) -Sha256Base64 $base64 2>$null
}
catch {
    $mismatchRejected = $true
}
if (-not $mismatchRejected) { throw 'A mismatched hexadecimal/base64 digest pair must be rejected.' }

Write-Output 'PASS: Lambda artifact digest pair is consistent and mismatch is rejected.'
