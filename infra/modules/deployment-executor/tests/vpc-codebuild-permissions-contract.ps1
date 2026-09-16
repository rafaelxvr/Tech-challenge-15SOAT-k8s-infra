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

Write-Output 'deployment executor VPC CodeBuild permission contract: PASS'
