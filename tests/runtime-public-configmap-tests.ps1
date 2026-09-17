[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$renderer = Join-Path $repoRoot 'scripts/render-runtime-public-configmap.ps1'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('oficina-runtime-public-' + [guid]::NewGuid().ToString('N'))
$keys = Join-Path $scratch 'customer-public-keys.yaml'
$ca = Join-Path $scratch 'rds-ca.pem'
$output = Join-Path $scratch 'rendered'

function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) {
    if (-not $Text.Contains($Expected)) { throw $Message }
}

try {
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    @'
security:
  jwt:
    customer:
      public-keys:
        customer-2026-09: |
          -----BEGIN PUBLIC KEY-----
          fixture-public-key
          -----END PUBLIC KEY-----
'@ | Set-Content -LiteralPath $keys -Encoding utf8
    @'
-----BEGIN CERTIFICATE-----
fixture-rds-ca
-----END CERTIFICATE-----
'@ | Set-Content -LiteralPath $ca -Encoding utf8

    $file = & $renderer -Environment staging -CustomerPublicKeysFile $keys -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-staging-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $ca -OutputDirectory $output
    $rendered = Get-Content -LiteralPath $file -Raw
    Assert-Contains $rendered 'name: oficina-runtime-public-staging' 'Renderer must scope the ConfigMap to the staging name.'
    Assert-Contains $rendered 'namespace: oficina-staging' 'Renderer must scope the ConfigMap to the staging namespace.'
    Assert-Contains $rendered 'customer-2026-09:' 'Renderer must carry the reviewed customer key mapping.'
    Assert-Contains $rendered 'staff-key-id: ''staff-2026-09''' 'Renderer must carry the reviewed staff key ID.'
    Assert-Contains $rendered 'oficina-phase3-staging-notifications.fifo' 'Renderer must carry the reviewed staging queue URL.'
    Assert-Contains $rendered 'rds-ca.pem:' 'Renderer must include the reviewed regional CA bundle.'
    if ($rendered -match '(?i)PRIVATE KEY|STAFF_HMAC|JWT_SECRET|PASSWORD|stringData:|\$\{[A-Z_]+\}') { throw 'Rendered public ConfigMap contains secrets or unresolved tokens.' }

    $invalidKeys = Join-Path $scratch 'invalid-keys.yaml'
    (Get-Content -LiteralPath $keys -Raw).Replace('BEGIN PUBLIC KEY', 'BEGIN PRIVATE KEY') | Set-Content -LiteralPath $invalidKeys -Encoding utf8
    $rejected = $false
    try { & $renderer -Environment staging -CustomerPublicKeysFile $invalidKeys -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-staging-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $ca -OutputDirectory $output | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Renderer accepted private key material.' }

    $rejected = $false
    try { & $renderer -Environment staging -CustomerPublicKeysFile $keys -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-production-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $ca -OutputDirectory $output | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Renderer accepted a cross-environment queue URL.' }

    Write-Output 'PASS: runtime-public ConfigMap renderer keeps staging handoff nonsecret and reviewable.'
}
finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    if (-not $resolvedScratch.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolvedScratch) { Remove-Item -LiteralPath $resolvedScratch -Recurse -Force }
}
