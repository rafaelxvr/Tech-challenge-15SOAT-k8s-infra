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
    [Parameter(Mandatory)] [string]$AuthorizerTrustSecretArn,
    [Parameter(Mandatory)] [string]$NewRelicIngestSecretArn,
    [Parameter(Mandatory)] [string]$NewRelicAccountId,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Image -cnotmatch '\A[0-9]{12}\.dkr\.ecr\.us-east-1\.amazonaws\.com/[a-z0-9][a-z0-9/_.-]*@sha256:[a-f0-9]{64}\z') { throw 'Image must be an immutable us-east-1 ECR image pinned to a lowercase SHA-256 digest.' }
$accountId = $Image.Split('.')[0]
foreach ($arn in @($AppIrsaRoleArn, $DeployerPrincipalArn, $PlatformBindingPrincipalArn)) {
    if ($arn -cnotmatch "\Aarn:aws:iam::${accountId}:role/[A-Za-z0-9/+=,.@_-]+\z") { throw 'IRSA and deployer inputs must be same-account IAM role ARNs.' }
}
if ($AppIrsaRoleArn -cnotmatch "[-/]${Environment}(-|\z)") { throw 'App IRSA role must identify the selected environment.' }
foreach ($entry in @(@{Arn=$AppSecretArn; Name='app'}, @{Arn=$AuthorizerTrustSecretArn; Name='authorizer-trust'}, @{Arn=$NewRelicIngestSecretArn; Name='newrelic-ingest'})) {
    if ($entry.Arn -cnotmatch ("\Aarn:aws:secretsmanager:us-east-1:${accountId}:secret:oficina/${Environment}/" + $entry.Name + '-[A-Za-z0-9]{6}\z')) { throw 'Runtime secrets must be the exact approved same-account environment references.' }
}
if ($DbHost -cnotmatch '\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z') { throw 'Database host must be a DNS hostname without a port, URL or whitespace.' }
if ($NewRelicAccountId -notmatch '^[1-9][0-9]{0,15}$') { throw 'NewRelicAccountId must be a nonsecret positive account identifier.' }
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
    '${AUTHORIZER_TRUST_SECRET_ARN}' = $AuthorizerTrustSecretArn
    '${NEW_RELIC_INGEST_SECRET_ARN}' = $NewRelicIngestSecretArn
    '${NEW_RELIC_ACCOUNT_ID}'    = $NewRelicAccountId
}
foreach ($token in $tokens.Keys) { $rendered = $rendered.Replace($token, $tokens[$token]) }
if ($rendered -match '\$\{[A-Z_]+\}') { throw 'Unresolved deployment input token in rendered platform manifest.' }

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = Join-Path $OutputDirectory "platform-$Environment.yaml"
Set-Content -LiteralPath $output -Value ($rendered -join "`n") -NoNewline
Write-Output $output
