[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('staging', 'production')]
    [string]$Environment,
    [Parameter(Mandatory)] [string]$Image,
    [Parameter(Mandatory)] [string]$TargetGroupArn,
    [Parameter(Mandatory)] [string]$AppIrsaRoleArn,
    [Parameter(Mandatory)] [string]$DeployerPrincipalArn,
    [Parameter(Mandatory)] [string]$DbHost,
    [Parameter(Mandatory)] [string]$DbCidr,
    [Parameter(Mandatory)] [string]$VpcCidr,
    [Parameter(Mandatory)] [string]$AppSecretArn,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Image -notmatch '@sha256:[a-f0-9]{64}$') { throw 'Image must be pinned to a lowercase SHA-256 digest.' }
if ($TargetGroupArn -notmatch '^arn:aws:elasticloadbalancing:us-east-1:[0-9]{12}:targetgroup/.+$') { throw 'TargetGroupArn must be a us-east-1 target-group ARN.' }
foreach ($arn in @($AppIrsaRoleArn, $DeployerPrincipalArn)) {
    if ($arn -notmatch '^arn:aws:iam::[0-9]{12}:role/.+$') { throw 'IRSA and deployer inputs must be IAM role ARNs.' }
}
if ($AppSecretArn -notmatch '^arn:aws:secretsmanager:us-east-1:[0-9]{12}:secret:.+$') { throw 'AppSecretArn must be a Secrets Manager ARN.' }
foreach ($cidr in @($DbCidr, $VpcCidr)) {
    if ($cidr -notmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$') { throw 'DbCidr and VpcCidr must be CIDR blocks.' }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$overlay = Join-Path $repoRoot "k8s/platform/overlays/$Environment"
$kubectl = Get-Command kubectl -ErrorAction Stop
$rendered = & $kubectl.Source kustomize $overlay
if ($LASTEXITCODE -ne 0) { throw 'kubectl kustomize failed.' }

$tokens = [ordered]@{
    '${APP_IMAGE}'               = $Image
    '${TARGET_GROUP_ARN}'        = $TargetGroupArn
    '${APP_IRSA_ROLE_ARN}'       = $AppIrsaRoleArn
    '${DEPLOYER_PRINCIPAL_ARN}'  = $DeployerPrincipalArn
    '${DB_HOST}'                 = $DbHost
    '${DB_CIDR}'                 = $DbCidr
    '${VPC_CIDR}'                = $VpcCidr
    '${APP_SECRET_ARN}'          = $AppSecretArn
}
foreach ($token in $tokens.Keys) { $rendered = $rendered.Replace($token, $tokens[$token]) }
if ($rendered -match '\$\{[A-Z_]+\}') { throw 'Unresolved deployment input token in rendered platform manifest.' }

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = Join-Path $OutputDirectory "platform-$Environment.yaml"
Set-Content -LiteralPath $output -Value $rendered -NoNewline
Write-Output $output
