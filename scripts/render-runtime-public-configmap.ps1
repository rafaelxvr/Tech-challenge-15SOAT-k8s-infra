[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('staging', 'production')] [string]$Environment,
    [Parameter(Mandatory)] [string]$CustomerPublicKeysFile,
    [Parameter(Mandatory)] [string]$StaffKeyId,
    [Parameter(Mandatory)] [string]$NotificationQueueUrl,
    [Parameter(Mandatory)] [string]$HistoryZone,
    [Parameter(Mandatory)] [string]$RdsCaFile,
    [Parameter(Mandatory)] [ValidatePattern('\A[a-f0-9]{64}\z')] [string]$ExpectedRdsCaSha256,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-RequiredFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label does not exist." }
    try { return [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path)) } catch { throw "$Label could not be read." }
}

function Read-CustomerPublicKeys {
    $content = Read-RequiredFile -Path $CustomerPublicKeysFile -Label 'Customer public keys file'
    if ([string]::IsNullOrWhiteSpace($content) -or $content -match '\$\{[^}]+\}') { throw 'Customer public keys must be a resolved nonempty YAML document.' }
    $lines = $content -split "`r?`n"
    $headers = @('security:', '  jwt:', '    customer:', '      public-keys:')
    for ($index = 0; $index -lt $headers.Count; $index++) {
        if ($lines[$index] -cne $headers[$index]) { throw 'Customer public keys must contain only the security.jwt.customer.public-keys YAML tree.' }
    }

    function Assert-PublicKeyBlock {
        param([Parameter(Mandatory)][string[]]$PemLines)
        $meaningful = @($PemLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($meaningful.Count -lt 3 -or $meaningful[0] -cne '-----BEGIN PUBLIC KEY-----' -or $meaningful[$meaningful.Count - 1] -cne '-----END PUBLIC KEY-----') {
            throw 'Customer public keys must contain an X.509 SubjectPublicKeyInfo PEM.'
        }
        $body = (($meaningful[1..($meaningful.Count - 2)] -join '') -replace '\s', '')
        if ($body -notmatch '^[A-Za-z0-9+/=]+$') { throw 'Customer public key PEM contains invalid base64.' }
        try { $der = [Convert]::FromBase64String($body) } catch { throw 'Customer public key PEM is not valid base64.' }
        $rsa = [Security.Cryptography.RSA]::Create()
        try {
            $read = 0
            $rsa.ImportSubjectPublicKeyInfo($der, [ref]$read)
            if ($read -ne $der.Length) { throw 'Customer public key PEM has trailing data.' }
        } catch { throw 'Customer public key PEM is not a valid RSA SubjectPublicKeyInfo key.' } finally { $rsa.Dispose() }
    }

    $currentKey = $null
    $pemLines = @()
    $keyCount = 0
    for ($index = $headers.Count; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^        (?<key>[A-Za-z0-9_-]{1,64}):\s*\|\s*$') {
            if ($null -ne $currentKey) { Assert-PublicKeyBlock -PemLines $pemLines }
            $currentKey = $Matches.key
            $pemLines = @()
            $keyCount++
            continue
        }
        if ($line -match '^ {10}(?<pem>.*)$' -and $null -ne $currentKey) {
            $pemLines += $Matches.pem
            continue
        }
        throw 'Customer public keys contain a field outside security.jwt.customer.public-keys.'
    }
    if ($null -ne $currentKey) { Assert-PublicKeyBlock -PemLines $pemLines }
    if ($keyCount -eq 0) { throw 'Customer public keys must contain at least one trusted key.' }
    return $content.TrimEnd("`r", "`n")
}

function Read-RdsCa {
    if (-not (Test-Path -LiteralPath $RdsCaFile -PathType Leaf)) { throw 'RDS CA file does not exist.' }
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $RdsCaFile))
    if ($bytes.Length -ge 65536) { throw 'RDS CA bundle is 64 KiB or larger.' }
    $actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($actualHash -cne $ExpectedRdsCaSha256) { throw 'RDS CA bytes do not match the reviewed bootstrap CA SHA-256.' }
    if ($bytes.Where({ $_ -gt 127 }).Count -gt 0) { throw 'RDS CA must be ASCII PEM without an encoding BOM.' }
    $content = [Text.Encoding]::ASCII.GetString($bytes)
    $pemPattern = '(?ms)^-----BEGIN CERTIFICATE-----\r?\n(?<body>[A-Za-z0-9+/=\r\n]+?)\r?\n-----END CERTIFICATE-----\r?$'
    $matches = [regex]::Matches($content, $pemPattern)
    if ($matches.Count -eq 0 -or ([regex]::Replace($content, $pemPattern, '').Trim().Length -ne 0)) { throw 'RDS CA file must contain only PEM certificates.' }
    foreach ($match in $matches) {
        try { $der = [Convert]::FromBase64String(($match.Groups['body'].Value -replace '\s', '')) } catch { throw 'RDS CA certificate is not valid base64.' }
        $certificate = $null
        try { $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($der) } catch { throw 'RDS CA certificate is not structurally valid.' } finally { if ($null -ne $certificate) { $certificate.Dispose() } }
    }
    return $content
}

function Assert-SafeScalar {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Label)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '[\r\n]' -or $Value -match '[{}\[\]]') { throw "$Label contains unsafe YAML characters." }
}

if ($StaffKeyId -notmatch '^[A-Za-z0-9_-]{1,64}$') { throw 'StaffKeyId must match [A-Za-z0-9_-]{1,64}.' }
if ($NotificationQueueUrl -notmatch "^https://sqs\.us-east-1\.amazonaws\.com/[0-9]{12}/oficina-phase3-$Environment-notifications\.fifo$") { throw 'NotificationQueueUrl must be the exact reviewed environment FIFO queue URL.' }
Assert-SafeScalar -Value $HistoryZone -Label 'HistoryZone'
if ($HistoryZone -notmatch '^[A-Za-z0-9_./+:-]+$') { throw 'HistoryZone must be a reviewed timezone or compatibility zone.' }

$customerPublicKeys = Read-CustomerPublicKeys
$rdsCa = Read-RdsCa
# JSON quoted scalars are valid YAML and preserve CRLF/LF and trailing newlines.
# Kubernetes mounts these exact UTF-8 bytes, matching the reviewed bootstrap hash.
$rdsCaScalar = ConvertTo-Json -InputObject $rdsCa -Compress
$indent = { param([string]$Value) ($Value -split "`r?`n" | ForEach-Object { "    $_" }) -join "`n" }
$configMap = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: oficina-runtime-public-$Environment
  namespace: oficina-$Environment
  labels:
    app.kubernetes.io/part-of: oficina
    app.kubernetes.io/managed-by: oficina-k8s-infra
data:
  customer-public-keys.yaml: |
$(& $indent $customerPublicKeys)
  staff-issuer: 'oficina-$Environment-staff'
  staff-audience: 'oficina-$Environment-api'
  staff-key-id: '$StaffKeyId'
  customer-issuer: 'oficina-$Environment-customer'
  customer-audience: 'oficina-$Environment-api'
  notification-queue-url: '$NotificationQueueUrl'
  history-zone: '$HistoryZone'
  rds-ca.pem: $rdsCaScalar
"@

if ($configMap -match '(?i)PRIVATE KEY|STAFF_HMAC|JWT_SECRET|PASSWORD|CLIENT_SECRET|ACCESS_KEY|SECRET_KEY|stringData:') { throw 'Rendered runtime-public ConfigMap contains secret material.' }
if ($configMap -match '\$\{[A-Z_]+\}') { throw 'Rendered runtime-public ConfigMap contains unresolved tokens.' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = Join-Path $OutputDirectory "runtime-public-$Environment.yaml"
Set-Content -LiteralPath $output -Value $configMap -NoNewline
Write-Output $output
