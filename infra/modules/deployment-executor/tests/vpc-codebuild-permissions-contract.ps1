$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$moduleRoot = Split-Path -Parent $PSScriptRoot
$terraform = Get-Content -Raw -LiteralPath (Join-Path $moduleRoot 'main.tf')

$requiredActions = @(
    'ec2:CreateNetworkInterface',
    'ec2:DescribeDhcpOptions',
    'ec2:DescribeNetworkInterfaces',
    'ec2:DeleteNetworkInterface',
    'ec2:DescribeSubnets',
    'ec2:DescribeSecurityGroups',
    'ec2:DescribeVpcs'
)
foreach ($action in $requiredActions) {
    if ($terraform -notmatch [regex]::Escape('"' + $action + '"')) {
        throw "VPC-configured CodeBuild projects must retain the documented $action action."
    }
}
if ($terraform -match 'ec2:\*') {
    throw 'The CodeBuild VPC policy must not grant wildcard EC2 actions.'
}
if ($terraform -notmatch '(?s)Sid\s*=\s*"CodeBuildVpcNetworkInterfaces".*?Action\s*=\s*local\.codebuild_vpc_project_actions.*?Resource\s*=\s*"\*"') {
    throw 'The CodeBuild VPC network-interface permissions must be in the common service-role policy with the documented IAM resource scope.'
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
Write-Output 'deployment executor VPC CodeBuild permission contract: PASS'
