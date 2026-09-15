[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InputFile,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputFile,

    # Used only by offline contract tests. Normal execution verifies the current caller through STS.
    [string]$CallerArnForTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$checker = Join-Path $PSScriptRoot 'check-deployment-inputs.ps1'
$checkerArguments = @{ InputFile = $InputFile }
if (-not [string]::IsNullOrWhiteSpace($CallerArnForTest)) {
    $checkerArguments.CallerArnForTest = $CallerArnForTest
}
& $checker @checkerArguments | Out-Null

$inputs = Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json
$launchers = [ordered]@{}
foreach ($launcher in @($inputs.launchers)) {
    $launchers[$launcher.name] = [ordered]@{
        repository            = $launcher.repository
        environment           = $launcher.environment
        branch                = $launcher.branch
        source_prefix         = $launcher.sourcePrefix
        codebuild_project_arn = $launcher.codeBuildProjectArn
    }
}

$tfvars = [ordered]@{
    aws_region               = $inputs.region
    account_id               = $inputs.accountId
    state_bucket_name        = $inputs.stateBucketName
    artifact_bucket_name     = $inputs.artifactBucketName
    github_oidc_provider_arn = $inputs.githubOidcProviderArn
    state_keys               = [ordered]@{
        bootstrap  = 'bootstrap/terraform.tfstate'
        foundation = 'foundation/terraform.tfstate'
        staging    = 'environments/staging/terraform.tfstate'
        production = 'environments/production/terraform.tfstate'
    }
    launchers         = $launchers
    runtime_role_arns = @()
}

$directory = Split-Path -Parent $OutputFile
if (-not [string]::IsNullOrWhiteSpace($directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$tfvars | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputFile -NoNewline
Write-Output 'Bootstrap Terraform variables file created from validated, secret-free inputs.'
