[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$foundation = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/foundation/main.tf') -Raw
$platform = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/modules/platform-environment/main.tf') -Raw
$policy = Get-Content -LiteralPath (Join-Path $repoRoot 'k8s/platform/base/network-policies.yaml') -Raw

function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) {
    if (-not $Text.Contains($Expected)) { throw $Message }
}

Assert-Contains $foundation 'resource "aws_lb" "internal"' 'Foundation must own the single shared internal ALB.'
Assert-Contains $foundation 'resource "aws_apigatewayv2_vpc_link" "internal"' 'Foundation must own the shared private VPC link.'
Assert-Contains $foundation 'for_each          = { staging = 8080, production = 8081 }' 'Foundation must define both reviewed listener ports.'
Assert-Contains $foundation 'status_code  = "503"' 'Listener default must fail safely before target binding exists.'
Assert-Contains $platform 'resource "aws_lb_listener_rule" "backend"' 'Each platform must create a listener forwarding rule.'
Assert-Contains $platform 'target_group_arn = aws_lb_target_group.app.arn' 'Listener rule must forward to its own environment target group.'
Assert-Contains $foundation 'system:serviceaccount:kube-system:aws-load-balancer-controller' 'Load-balancer controller trust must name one exact service account.'
foreach ($pin in @('version          = "1.12.0"', 'version          = "3.12.2"', 'version          = "1.4.8"', 'version          = "0.3.9"')) {
    Assert-Contains $foundation $pin "Missing required pinned platform chart $pin."
}
foreach ($request in @('cpu = "100m", memory = "128Mi"', 'cpu = "50m", memory = "64Mi"')) {
    Assert-Contains $foundation $request "Missing controller resource request $request."
}
Assert-Contains $policy 'oficina.io/environment: ${ENVIRONMENT}' 'Actual app policy must allow only its own namespace label.'
Assert-Contains $policy '${ALB_SUBNET_CIDR_ONE}' 'Actual app policy must permit the first ALB source subnet only.'
Assert-Contains $policy '${ALB_SUBNET_CIDR_TWO}' 'Actual app policy must permit the second ALB source subnet only.'
if ($policy.Contains('${VPC_CIDR}')) { throw 'Actual app policy must not permit every source in the VPC.' }
if ($foundation -match 'secret_string|secret_binary') { throw 'Platform foundation must not store secret values in Terraform.' }

Write-Output 'PASS: actual foundation and platform sources bind safe listeners, pinned controllers, exact IRSA, and isolated manifest policy.'
