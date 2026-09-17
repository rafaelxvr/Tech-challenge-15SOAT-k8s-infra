[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$module = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/modules/platform-environment/main.tf') -Raw
$variables = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/modules/platform-environment/variables.tf') -Raw
$contractPath = Join-Path $repoRoot 'infra/modules/platform-environment/contracts/phase3-v2/routes.json'
$contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
$contractHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $contractPath).Hash.ToLowerInvariant()

function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) {
    if (-not $Text.Contains($Expected)) { throw $Message }
}

if ($contract.defaultDecision -ne 'DENY') { throw 'The gateway contract must default deny.' }
if ($contractHash -ne '7e1cff5e6c57174af792bb44b33e63572f885698ab5ef2f24d5aeebda883c1a8') { throw 'The vendored route matrix no longer matches APP phase3-v2.' }
if (-not ($contract.routes | Where-Object { $_.method -eq 'GET' -and $_.path -eq '/api/admin/relatorios/ordens' -and $_.decision -eq 'ALLOW' })) { throw 'phase3-v2 must include the protected ADMIN report route.' }
if (-not ($contract.routes | Where-Object { $_.path -eq '/api/ordens-servico/email/atualizar-status' -and $_.decision -eq 'DENY' })) { throw 'The retired email mutation must remain denied.' }
Assert-Contains $module 'contracts/phase3-v2/routes.json' 'The platform must consume the vendored immutable v2 route matrix.'
Assert-Contains $variables 'variable "authorizer_handoff"' 'The platform must accept the reviewed FUN API/authorizer handoff object.'
Assert-Contains $module 'if contains(local.public_app_routes, route_key) || var.authorizer_handoff != null' 'Protected routes must remain absent until the FUN handoff is supplied.'
Assert-Contains $module 'resource "aws_cloudwatch_log_group" "gateway"' 'Gateway access logs must have an owned bounded destination.'
Assert-Contains $module 'authorizerError    = "$context.authorizer.error"' 'Gateway logs must preserve safe authorizer diagnostic category.'
if ($module -match 'aws_apigatewayv2_authorizer|aws_lambda_permission|aws_lambda_function_url|identity_sources\s*=|route_key\s*=\s*"\$default"') { throw 'The K8S platform must not own the FUN authorizer, Lambda permissions, Function URLs, or permissive default route.' }
if ($module -notmatch 'allow_credentials = false' -or $module -notmatch 'allow_origins     = var.cors_allow_origins') { throw 'CORS must use explicit caller origins without credentials.' }

Write-Output 'PASS: phase3-v2 routes, two-phase authorizer handoff, denied defaults, bounded CORS, and safe gateway logs are enforced.'
