$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$moduleRoot = Split-Path -Parent $PSScriptRoot
$terraform = Get-Content -Raw -LiteralPath (Join-Path $moduleRoot 'main.tf')

foreach ($required in @(
  'foundation-addons/terraform\.tfstate',
  'foundation-addons/bundle\.zip',
  'aws_eks_access_entry" "foundation_addons"',
  'aws_eks_access_policy_association" "foundation_addons"',
  'AmazonEKSClusterAdminPolicy',
  'access_scope \{ type = "cluster" \}',
  'BUILD_GENERAL1_SMALL',
  'image_pull_credentials_type = "SERVICE_ROLE"',
  'vpc_config',
  'codebuild_vpc_network_interface_actions',
  'ADDONS_SOURCE_VERSION_ID',
  'ADDONS_EXPECTED_SHA256',
  'ADDONS_MANIFEST_VERSION_ID',
  'ADDONS_SOURCE_COMMIT',
  'sha256sum',
  'release/infra/foundation-addons/main.tf'
)) {
  if ($terraform -notmatch $required) { throw "Missing private foundation-addons executor contract: $required" }
}

foreach ($action in @('ec2:CreateNetworkInterface', 'ec2:DescribeDhcpOptions', 'ec2:DescribeNetworkInterfaces', 'ec2:DeleteNetworkInterface', 'ec2:DescribeSubnets', 'ec2:DescribeSecurityGroups', 'ec2:DescribeVpcs')) {
  if ($terraform -notmatch [regex]::Escape('"' + $action + '"')) { throw "Missing documented CodeBuild VPC action: $action" }
}
if ($terraform -match 'ec2:\*') { throw 'Foundation addons executor must not grant wildcard EC2 actions.' }
if ($terraform -notmatch 'Sid\s*=\s*"CodeBuildVpcNetworkInterfaces".*Action\s*=\s*local\.codebuild_vpc_network_interface_actions.*Resource\s*=\s*"\*"') {
  throw 'Foundation addons executor must apply the documented VPC actions with the required IAM resource scope.'
}
if ($terraform -match 'iam:Create|eks:Update|s3:DeleteObject"\], Resource = "arn:aws:s3:::.*terraform\.tfstate"') {
  throw 'The foundation-addons executor must not receive broad IAM/EKS write permissions or delete its state object.'
}
$requiredPermission = @'
{
  Sid = "CodeBuildVpcNetworkInterfacePermission"
  Effect = "Allow"
  Action = "ec2:CreateNetworkInterfacePermission"
  Resource = "arn:aws:ec2:${var.aws_region}:${var.account_id}:network-interface/*"
  Condition = {
    StringEquals = { "ec2:AuthorizedService" = "codebuild.amazonaws.com" }
    ArnEquals = { "ec2:Subnet" = [for subnet in var.private_subnet_ids : "arn:aws:ec2:${var.aws_region}:${var.account_id}:subnet/${subnet}"] }
  }
}
'@
if (-not ($terraform -replace '\s', '').Contains(($requiredPermission -replace '\s', ''))) {
    throw 'CodeBuild requires CreateNetworkInterfacePermission limited to configured account/region ENIs, its private subnets, and the CodeBuild authorized service.'
}
if ([regex]::Matches($terraform, '"ec2:CreateNetworkInterfacePermission"').Count -ne 1) {
    throw 'The ENI permission must appear only in its separately scoped statement, never in the Resource=* action list.'
}
Write-Output 'foundation-addons executor contract: PASS'
