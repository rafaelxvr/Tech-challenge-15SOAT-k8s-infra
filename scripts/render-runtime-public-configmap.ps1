[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('staging', 'production')] [string]$Environment,
    [Parameter(Mandatory)] [string]$CustomerPublicKeysFile,
    [Parameter(Mandatory)] [string]$StaffKeyId,
    [Parameter(Mandatory)] [string]$NotificationQueueUrl,
    [Parameter(Mandatory)] [string]$HistoryZone,
    [Parameter(Mandatory)] [string]$RdsCaFile,
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
    if ($content -notmatch '(?m)^\s*security:\s*$' -or $content -notmatch '(?m)^\s*jwt:\s*$' -or $content -notmatch '(?m)^\s*customer:\s*$' -or $content -notmatch '(?m)^\s*public-keys:\s*$') {
        throw 'Customer public keys must contain only the security.jwt.customer.public-keys YAML tree.'
    }
    if ($content -notmatch '(?m)^\s*-----BEGIN PUBLIC KEY-----\s*$' -or $content -notmatch '(?m)^\s*-----END PUBLIC KEY-----\s*$') { throw 'Customer public keys must contain an X.509 SubjectPublicKeyInfo PEM.' }
    if ($content -match '(?i)PRIVATE KEY|STAFF_HMAC|JWT_SECRET|PASSWORD|CLIENT_SECRET|ACCESS_KEY|SECRET_KEY|stringData:') { throw 'Customer public keys contain a secret or disallowed configuration field.' }
    return $content.TrimEnd("`r", "`n")
}

function Read-RdsCa {
    if (-not (Test-Path -LiteralPath $RdsCaFile -PathType Leaf)) { throw 'RDS CA file does not exist.' }
    $file = Get-Item -LiteralPath $RdsCaFile
    if ($file.Length -ge 65536) { throw 'RDS CA bundle is 64 KiB or larger.' }
    $content = Read-RequiredFile -Path $RdsCaFile -Label 'RDS CA file'
    if ($content -notmatch '(?m)^-----BEGIN CERTIFICATE-----\r?$' -or $content -notmatch '(?m)^-----END CERTIFICATE-----\r?$') { throw 'RDS CA file must contain PEM certificates.' }
    if ($content -match '(?i)PRIVATE KEY|SECRET|PASSWORD') { throw 'RDS CA file contains disallowed secret material.' }
    return $content.TrimEnd("`r", "`n")
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
  rds-ca.pem: |
$(& $indent $rdsCa)
"@

if ($configMap -match '(?i)PRIVATE KEY|STAFF_HMAC|JWT_SECRET|PASSWORD|CLIENT_SECRET|ACCESS_KEY|SECRET_KEY|stringData:') { throw 'Rendered runtime-public ConfigMap contains secret material.' }
if ($configMap -match '\$\{[A-Z_]+\}') { throw 'Rendered runtime-public ConfigMap contains unresolved tokens.' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = Join-Path $OutputDirectory "runtime-public-$Environment.yaml"
Set-Content -LiteralPath $output -Value $configMap -NoNewline
Write-Output $output
