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
    function Convert-ToPem {
        param([byte[]]$Bytes, [string]$Begin, [string]$End)
        $base64 = [Convert]::ToBase64String($Bytes)
        $lines = @()
        for ($index = 0; $index -lt $base64.Length; $index += 64) { $lines += $base64.Substring($index, [Math]::Min(64, $base64.Length - $index)) }
        return (($Begin + "`n" + ($lines -join "`n") + "`n" + $End))
    }
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $certificate = $null
    try {
        $publicPem = Convert-ToPem -Bytes $rsa.ExportSubjectPublicKeyInfo() -Begin '-----BEGIN PUBLIC KEY-----' -End '-----END PUBLIC KEY-----'
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=fixture-rds', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30))
        $caPem = Convert-ToPem -Bytes $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert) -Begin '-----BEGIN CERTIFICATE-----' -End '-----END CERTIFICATE-----'
    } finally {
        if ($null -ne $certificate) { $certificate.Dispose() }
        $rsa.Dispose()
    }
    $keyDocument = @('security:', '  jwt:', '    customer:', '      public-keys:', '        customer-2026-09: |') -join "`n"
    $keyDocument += "`n"
    $keyDocument += (($publicPem -split "`r?`n" | ForEach-Object { "          $_" }) -join "`n") + "`n"
    Set-Content -LiteralPath $keys -Value $keyDocument -Encoding utf8
    Set-Content -LiteralPath $ca -Value $caPem -Encoding utf8

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

    $invalidKeys = Join-Path $scratch 'invalid-base64-keys.yaml'
    (Get-Content -LiteralPath $keys -Raw).Replace('A', '!') | Set-Content -LiteralPath $invalidKeys -Encoding utf8
    $rejected = $false
    try { & $renderer -Environment staging -CustomerPublicKeysFile $invalidKeys -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-staging-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $ca -OutputDirectory $output | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Renderer accepted arbitrary public-key content.' }

    $invalidCa = Join-Path $scratch 'invalid-ca.pem'
    (Get-Content -LiteralPath $ca -Raw).Replace('A', '!') | Set-Content -LiteralPath $invalidCa -Encoding utf8
    $rejected = $false
    try { & $renderer -Environment staging -CustomerPublicKeysFile $keys -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-staging-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $invalidCa -OutputDirectory $output | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Renderer accepted arbitrary RDS CA marker content.' }

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
