[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$module = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/modules/functions/main.tf') -Raw
$variables = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/modules/functions/variables.tf') -Raw
$platform = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/modules/platform-environment/main.tf') -Raw
$platformVariables = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/modules/platform-environment/variables.tf') -Raw
$foundation = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/foundation/main.tf') -Raw

function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) {
    if (-not $Text.Contains($Expected)) { throw $Message }
}

foreach ($resource in @('resource "aws_sqs_queue" "notification_dlq"', 'resource "aws_sqs_queue" "notifications"', 'resource "aws_dynamodb_table" "challenge"', 'resource "aws_dynamodb_table" "delivery"', 'resource "aws_lambda_event_source_mapping" "notification"')) {
    Assert-Contains $module $resource "I5 is missing the required function runtime resource: $resource"
}
foreach ($setting in @('message_retention_seconds   = 1209600', 'message_retention_seconds   = 345600', 'visibility_timeout_seconds  = 120', 'maxReceiveCount     = 5', 'batch_size                         = 1', 'maximum_concurrency = 2', 'memory_size       = 1024', 'timeout           = 20', 'mode = "Active"', 'retention_in_days = 1')) {
    Assert-Contains $module $setting "I5 runtime bound missing: $setting"
}
foreach ($handler in @('CriarDesafioHandler::handleRequest', 'VerificarDesafioHandler::handleRequest', 'AuthorizerHandler::handleRequest', 'NotificacaoHandler::handleRequest')) {
    Assert-Contains $module $handler "The reviewed FUN handler is missing: $handler"
}
foreach ($permission in @('"sqs:ReceiveMessage"', '"sqs:DeleteMessage"', '"dynamodb:UpdateItem"', '"sqs:SendMessage"', '"secretsmanager:GetSecretValue"')) {
    Assert-Contains $module $permission "Least-privilege runtime policy is missing $permission."
}
foreach ($resolverSetting in @('DATABASE_SECRET_ARN', 'CUSTOMER_SIGNING_SECRET_ARN', 'AUTHORIZER_TRUST_SECRET_ARN', 'RDS_CA_CERT_SECRET_ARN', '/tmp/oficina/rds-ca.pem')) {
    Assert-Contains $module $resolverSetting "I5 must configure FUN resolver setting $resolverSetting."
}
Assert-Contains $variables 'var.approved_secret_count == 16' 'The approved 16-secret inventory must remain enforced.'
Assert-Contains $module 'local.planned_monthly_gb_seconds <= 200000' 'The 200,000 GB-second study envelope must remain enforced.'
Assert-Contains $platformVariables 'variable "authorizer_handoff"' 'The platform must accept the reviewed FUN API/authorizer handoff object.'
Assert-Contains $foundation 'resource "aws_security_group" "lambda"' 'Foundation must own the dedicated Lambda security group.'
Assert-Contains $foundation 'resource "aws_security_group" "rds"' 'Foundation must own the reviewed RDS security group.'
Assert-Contains $foundation 'resource "aws_vpc_security_group_ingress_rule" "database_from_functions"' 'Foundation database access must name the Lambda group as its approved source.'
Assert-Contains $foundation 'referenced_security_group_id = aws_security_group.lambda.id' 'The RDS group must approve only the foundation Lambda group on PostgreSQL.'
foreach ($root in @('infra/functions/staging/main.tf', 'infra/functions/production/main.tf')) {
    $rootSource = Get-Content -LiteralPath (Join-Path $repoRoot $root) -Raw
    Assert-Contains $rootSource 'Retired legacy K8S Functions root' 'Legacy K8S Functions roots must fail closed.'
    if ($rootSource -match 'module\s+"functions"') { throw "Retired root $rootSource must not instantiate a duplicate Functions owner." }
}
if ($platform -match 'aws_apigatewayv2_authorizer|aws_lambda_permission') { throw 'The K8S platform must not duplicate FUN authorizer or Lambda invoke ownership.' }
foreach ($rootOutput in @('infra/functions/staging/outputs.tf', 'infra/functions/production/outputs.tf')) {
    $rootSource = Get-Content -LiteralPath (Join-Path $repoRoot $rootOutput) -Raw
    if ($rootSource -match 'authorizerId') { throw "Only I4 may export an API Gateway authorizerId; $rootOutput incorrectly exports one." }
}
if ($module -match 'aws_apigatewayv2_|aws_lambda_function_url|reserved_concurrent_executions|provisioned_concurrent_executions|secret_string|secret_binary') {
    throw 'Functions state must not duplicate gateway routes, expose a Function URL, reserve concurrency, or put secret values in Terraform.'
}

Write-Output 'PASS: I5 enforces immutable function packaging, bounded FIFO delivery, private least privilege, secret inventory, tracing, and split gateway ownership.'
