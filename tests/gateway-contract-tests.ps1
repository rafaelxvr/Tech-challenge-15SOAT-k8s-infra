[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$module = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/modules/platform-environment/main.tf') -Raw
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
Assert-Contains $module 'resource "aws_apigatewayv2_authorizer" "request"' 'A Lambda REQUEST authorizer is required.'
Assert-Contains $module 'authorizer_result_ttl_in_seconds  = 0' 'Authorizer result caching must remain disabled.'
Assert-Contains $module 'enable_simple_responses           = true' 'The authorizer must use v2 simple responses.'
Assert-Contains $module 'resource "aws_lambda_permission" "authorizer"' 'The authorizer requires an exact API Gateway invoke permission.'
Assert-Contains $module 'resource "aws_lambda_permission" "auth_route"' 'CPF functions require exact route invoke permissions.'
Assert-Contains $module 'resource "aws_cloudwatch_log_group" "gateway"' 'Gateway access logs must have an owned bounded destination.'
Assert-Contains $module 'authorizerError    = "$context.authorizer.error"' 'Gateway logs must preserve safe authorizer diagnostic category.'
if ($module -match 'aws_lambda_function_url|identity_sources\s*=|route_key\s*=\s*"\$default"') { throw 'The platform must not create Function URLs, configure authorizer identity sources, or add a permissive default route.' }
if ($module -notmatch 'allow_credentials = false' -or $module -notmatch 'allow_origins     = var.cors_allow_origins') { throw 'CORS must use explicit caller origins without credentials.' }

Write-Output 'PASS: phase3-v2 routes, Lambda authorizer permissions, denied defaults, bounded CORS, and safe gateway logs are enforced.'
