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
. (Join-Path $repoRoot 'scripts/platform-manifest-contract.ps1')

function Assert-CaBytes([string]$ManifestFile, [string]$ExpectedHash) {
    $documents=Read-PlatformManifest $ManifestFile
    $data=$documents[0].data
    $mountedBytes=[Text.Encoding]::UTF8.GetBytes($data.'rds-ca.pem')
    $mountedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($mountedBytes)).ToLowerInvariant()
    if($mountedHash -cne $ExpectedHash){throw 'Mounted ConfigMap CA bytes differ from the reviewed file hash.'}
    foreach($property in $data.PSObject.Properties){if($property.Value -isnot [string]){throw 'ConfigMap data must contain only strings.'}}
}

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
    function New-CustomerKeyDocument {
        param([Parameter(Mandatory)][string[]]$KeyIds, [Parameter(Mandatory)][string]$PublicPem)
        $pem = (($PublicPem -split "`r?`n" | ForEach-Object { "          $_" }) -join "`n")
        $document = @('security:', '  jwt:', '    customer:', '      public-keys:') -join "`n"
        foreach ($keyId in $KeyIds) { $document += "`n        ${keyId}: |`n$pem" }
        return $document + "`n"
    }
    Set-Content -LiteralPath $keys -Value (New-CustomerKeyDocument -KeyIds @('customer-2026-09') -PublicPem $publicPem) -Encoding utf8
    Set-Content -LiteralPath $ca -Value $caPem -Encoding utf8
    $caHash=(Get-FileHash -LiteralPath $ca -Algorithm SHA256).Hash.ToLowerInvariant()

    $file = & $renderer -Environment staging -CustomerPublicKeysFile $keys -CustomerKeyId 'customer-2026-09' -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-staging-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $ca -ExpectedRdsCaSha256 $caHash -OutputDirectory $output
    $rendered = Get-Content -LiteralPath $file -Raw
    Assert-CaBytes $file $caHash
    Assert-Contains $rendered 'name: oficina-runtime-public-staging' 'Renderer must scope the ConfigMap to the staging name.'
    Assert-Contains $rendered 'namespace: oficina-staging' 'Renderer must scope the ConfigMap to the staging namespace.'
    Assert-Contains $rendered 'customer-2026-09:' 'Renderer must carry the reviewed customer key mapping.'
    Assert-Contains $rendered 'staff-key-id: ''staff-2026-09''' 'Renderer must carry the reviewed staff key ID.'
    Assert-Contains $rendered 'oficina-phase3-staging-notifications.fifo' 'Renderer must carry the reviewed staging queue URL.'
    Assert-Contains $rendered 'rds-ca.pem:' 'Renderer must include the reviewed regional CA bundle.'
    if ($rendered -match '(?i)PRIVATE KEY|STAFF_HMAC|JWT_SECRET|PASSWORD|stringData:|\$\{[A-Z_]+\}') { throw 'Rendered public ConfigMap contains secrets or unresolved tokens.' }

    foreach($variant in @($caPem, ($caPem+"`n"), ($caPem+"`n`n"), $caPem.Replace("`n","`r`n"), ($caPem.Replace("`n","`r`n")+"`r`n"))) {
        [IO.File]::WriteAllText($ca,$variant,[Text.UTF8Encoding]::new($false))
        $caHash=(Get-FileHash -LiteralPath $ca -Algorithm SHA256).Hash.ToLowerInvariant()
        foreach($environment in @('staging','production')) {
            $file=& $renderer -Environment $environment -CustomerPublicKeysFile $keys -CustomerKeyId 'customer-2026-09' -StaffKeyId 'staff-2026-09' -NotificationQueueUrl "https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-$environment-notifications.fifo" -HistoryZone 'UTC' -RdsCaFile $ca -ExpectedRdsCaSha256 $caHash -OutputDirectory $output
            Assert-CaBytes $file $caHash
        }
    }
    $rejectedOutput=Join-Path $scratch 'rejected-hash'
    $rejected=$false
    try { & $renderer -Environment staging -CustomerPublicKeysFile $keys -CustomerKeyId 'customer-2026-09' -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-staging-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $ca -ExpectedRdsCaSha256 ('0'*64) -OutputDirectory $rejectedOutput | Out-Null } catch { $rejected=$true }
    if(-not $rejected -or (Test-Path -LiteralPath $rejectedOutput)){throw 'A mismatched reviewed CA hash must fail before emitting output.'}
    $bomCa=Join-Path $scratch 'bom-ca.pem'
    [IO.File]::WriteAllText($bomCa,$caPem,[Text.UTF8Encoding]::new($true))
    $rejected=$false
    try { & $renderer -Environment staging -CustomerPublicKeysFile $keys -CustomerKeyId 'customer-2026-09' -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-staging-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $bomCa -ExpectedRdsCaSha256 ((Get-FileHash -LiteralPath $bomCa -Algorithm SHA256).Hash.ToLowerInvariant()) -OutputDirectory $rejectedOutput | Out-Null } catch { $rejected=$true }
    if(-not $rejected -or (Test-Path -LiteralPath $rejectedOutput)){throw 'A BOM must be rejected instead of silently changing the mounted CA bytes.'}

    $invalidKeys = Join-Path $scratch 'invalid-keys.yaml'
    (Get-Content -LiteralPath $keys -Raw).Replace('BEGIN PUBLIC KEY', 'BEGIN PRIVATE KEY') | Set-Content -LiteralPath $invalidKeys -Encoding utf8
    $rejected = $false
    try { & $renderer -Environment staging -CustomerPublicKeysFile $invalidKeys -CustomerKeyId 'customer-2026-09' -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-staging-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $ca -ExpectedRdsCaSha256 $caHash -OutputDirectory $output | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Renderer accepted private key material.' }

    $invalidKeys = Join-Path $scratch 'invalid-base64-keys.yaml'
    (Get-Content -LiteralPath $keys -Raw).Replace('A', '!') | Set-Content -LiteralPath $invalidKeys -Encoding utf8
    $rejected = $false
    try { & $renderer -Environment staging -CustomerPublicKeysFile $invalidKeys -CustomerKeyId 'customer-2026-09' -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-staging-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $ca -ExpectedRdsCaSha256 $caHash -OutputDirectory $output | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Renderer accepted arbitrary public-key content.' }

    $invalidCa = Join-Path $scratch 'invalid-ca.pem'
    (Get-Content -LiteralPath $ca -Raw).Replace('A', '!') | Set-Content -LiteralPath $invalidCa -Encoding utf8
    $rejected = $false
    try { & $renderer -Environment staging -CustomerPublicKeysFile $keys -CustomerKeyId 'customer-2026-09' -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-staging-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $invalidCa -ExpectedRdsCaSha256 ((Get-FileHash -LiteralPath $invalidCa -Algorithm SHA256).Hash.ToLowerInvariant()) -OutputDirectory $output | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Renderer accepted arbitrary RDS CA marker content.' }

    $rejected = $false
    try { & $renderer -Environment staging -CustomerPublicKeysFile $keys -CustomerKeyId 'customer-2026-09' -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-production-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $ca -ExpectedRdsCaSha256 $caHash -OutputDirectory $output | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Renderer accepted a cross-environment queue URL.' }

    $rejected = $false
    try { & $renderer -Environment staging -CustomerPublicKeysFile $keys -CustomerKeyId 'customer-2026-01' -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-staging-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $ca -ExpectedRdsCaSha256 $caHash -OutputDirectory $output | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Renderer accepted a signer kid that the customer public keys file does not publish.' }

    $rotatingKeys = Join-Path $scratch 'rotating-keys.yaml'
    Set-Content -LiteralPath $rotatingKeys -Encoding utf8 -Value (New-CustomerKeyDocument -KeyIds @('customer-2026-01', 'customer-2026-09') -PublicPem $publicPem)
    $file = & $renderer -Environment staging -CustomerPublicKeysFile $rotatingKeys -CustomerKeyId 'customer-2026-09' -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-staging-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $ca -ExpectedRdsCaSha256 $caHash -OutputDirectory $output
    $rendered = Get-Content -LiteralPath $file -Raw
    Assert-Contains $rendered 'customer-2026-01:' 'Renderer must retain the retired kid during a reviewed rotation overlap.'
    Assert-Contains $rendered 'customer-2026-09:' 'Renderer must carry the active signer kid during a reviewed rotation overlap.'

    $duplicateKeys = Join-Path $scratch 'duplicate-keys.yaml'
    Set-Content -LiteralPath $duplicateKeys -Encoding utf8 -Value (New-CustomerKeyDocument -KeyIds @('customer-2026-09', 'customer-2026-09') -PublicPem $publicPem)
    $rejected = $false
    try { & $renderer -Environment staging -CustomerPublicKeysFile $duplicateKeys -CustomerKeyId 'customer-2026-09' -StaffKeyId 'staff-2026-09' -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/123456789012/oficina-phase3-staging-notifications.fifo' -HistoryZone 'UTC' -RdsCaFile $ca -ExpectedRdsCaSha256 $caHash -OutputDirectory $output | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Renderer accepted a duplicated customer kid.' }

    Write-Output 'PASS: runtime-public ConfigMap preserves reviewed CA hashes across 5 byte layouts and both environments; mismatched hashes, BOMs, unpublished signer kids, duplicated kids and invalid inputs rejected.'
}
finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    if (-not $resolvedScratch.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolvedScratch) { Remove-Item -LiteralPath $resolvedScratch -Recurse -Force }
}
