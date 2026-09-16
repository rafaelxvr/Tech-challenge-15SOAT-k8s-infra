[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('staging', 'production')]
    [string]$Environment,
    [Parameter(Mandatory)] [string]$Image,
    [Parameter(Mandatory)] [string]$AppIrsaRoleArn,
    [Parameter(Mandatory)] [string]$DeployerPrincipalArn,
    [Parameter(Mandatory)] [string]$PlatformBindingPrincipalArn,
    [Parameter(Mandatory)] [string]$DbHost,
    [Parameter(Mandatory)] [string]$DbCidr,
    [Parameter(Mandatory)] [string]$AlbSubnetCidrOne,
    [Parameter(Mandatory)] [string]$AlbSubnetCidrTwo,
    [Parameter(Mandatory)] [string]$AppSecretArn,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Image -notmatch '@sha256:[a-f0-9]{64}$') { throw 'Image must be pinned to a lowercase SHA-256 digest.' }
foreach ($arn in @($AppIrsaRoleArn, $DeployerPrincipalArn, $PlatformBindingPrincipalArn)) {
    if ($arn -notmatch '^arn:aws:iam::[0-9]{12}:role/.+$') { throw 'IRSA and deployer inputs must be IAM role ARNs.' }
}
if ($AppSecretArn -notmatch '^arn:aws:secretsmanager:us-east-1:[0-9]{12}:secret:.+$') { throw 'AppSecretArn must be a Secrets Manager ARN.' }
foreach ($cidr in @($DbCidr, $AlbSubnetCidrOne, $AlbSubnetCidrTwo)) {
    if ($cidr -notmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$') { throw 'Database and ALB subnet inputs must be CIDR blocks.' }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$overlay = Join-Path $repoRoot "k8s/platform/overlays/$Environment"
$kubectl = Get-Command kubectl -ErrorAction Stop
$rendered = & $kubectl.Source kustomize $overlay
if ($LASTEXITCODE -ne 0) { throw 'kubectl kustomize failed.' }

$tokens = [ordered]@{
    '${APP_IMAGE}'               = $Image
    '${APP_IRSA_ROLE_ARN}'       = $AppIrsaRoleArn
    '${DEPLOYER_PRINCIPAL_ARN}'  = $DeployerPrincipalArn
    '${PLATFORM_BINDING_PRINCIPAL_ARN}' = $PlatformBindingPrincipalArn
    '${DB_HOST}'                 = $DbHost
    '${DB_CIDR}'                 = $DbCidr
    '${ALB_SUBNET_CIDR_ONE}'     = $AlbSubnetCidrOne
    '${ALB_SUBNET_CIDR_TWO}'     = $AlbSubnetCidrTwo
    '${ENVIRONMENT}'             = $Environment
    '${APP_SECRET_ARN}'          = $AppSecretArn
}
foreach ($token in $tokens.Keys) { $rendered = $rendered.Replace($token, $tokens[$token]) }
if ($rendered -match '\$\{[A-Z_]+\}') { throw 'Unresolved deployment input token in rendered platform manifest.' }

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = Join-Path $OutputDirectory "platform-$Environment.yaml"
Set-Content -LiteralPath $output -Value $rendered -NoNewline
Write-Output $output
