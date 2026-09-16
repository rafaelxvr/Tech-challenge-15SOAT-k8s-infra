$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$moduleRoot = Split-Path -Parent $PSScriptRoot
$terraform = Get-Content -Raw -LiteralPath (Join-Path $moduleRoot 'main.tf')

if ($terraform -notmatch 'codebuild_vpc_project_actions\s*=\s*\["ec2:DescribeSecurityGroups"\]') {
    throw 'VPC-configured CodeBuild projects must retain the required ec2:DescribeSecurityGroups action.'
}
if ($terraform -notmatch '(?s)Sid\s*=\s*"DescribeSecurityGroupsForPrivateBuild".*?Action\s*=\s*local\.codebuild_vpc_project_actions.*?Resource\s*=\s*"\*"') {
    throw 'The CodeBuild VPC security-group describe permission must be in the common service-role policy with the required IAM resource scope.'
}

Write-Output 'deployment executor VPC CodeBuild permission contract: PASS'
