[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$module=Get-Content -Raw "$root/infra/modules/platform-environment/main.tf"
$staging=Get-Content -Raw "$root/infra/environments/staging/main.tf"
$production=Get-Content -Raw "$root/infra/environments/production/main.tf"
$binding=Get-Content -Raw "$root/k8s/platform/base/deployer-rbac.yaml"
function Check([bool]$value,[string]$message){if(-not $value){throw $message}}
Check ($module.Contains('resource "aws_eks_access_entry" "app_deployer"')) 'Separate APP access entry is missing.'
Check ($module -match 'user_name\s*=\s*var.app_deployer_principal_arn') 'Username must match exact IAM-ARN RoleBinding identity.'
Check ($staging -match 'app_deployer_principal_arn\s*=\s*var.foundation_outputs.codebuild_projects\["app_staging"\].roleArn') 'Staging must use its reviewed APP executor output.'
Check (-not $production.Contains('app_deployer_principal_arn')) 'Production must not enable an APP entry.'
Check (-not $module.Contains('aws_eks_access_policy_association')) 'Access policies must not bypass namespace RBAC.'
Check ($binding.Contains('name: ${DEPLOYER_PRINCIPAL_ARN}')) 'Rendered RoleBinding must retain its literal IAM-ARN User contract.'
Write-Output 'PASS: separate staging APP entry, explicit User identity, existing RBAC contract, production isolation, no policy association.'
