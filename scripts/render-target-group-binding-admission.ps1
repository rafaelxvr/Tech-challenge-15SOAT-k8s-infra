[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$StagingTargetGroupArn,
    [Parameter(Mandatory)] [string]$ProductionTargetGroupArn,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-EnvironmentTargetGroupArn([string]$Environment, [string]$Arn) {
    if ($Arn -notmatch "^arn:aws:elasticloadbalancing:us-east-1:[0-9]{12}:targetgroup/oficina-$Environment[-/].+$") {
        throw "$Environment target group ARN must name the reviewed oficina-$Environment target group."
    }
}

Assert-EnvironmentTargetGroupArn -Environment 'staging' -Arn $StagingTargetGroupArn
Assert-EnvironmentTargetGroupArn -Environment 'production' -Arn $ProductionTargetGroupArn

$repoRoot = Split-Path -Parent $PSScriptRoot
$template = Get-Content -LiteralPath (Join-Path $repoRoot 'k8s/platform/admission/target-group-binding-admission.yaml') -Raw
$rendered = $template.Replace('${STAGING_TARGET_GROUP_ARN}', $StagingTargetGroupArn).Replace('${PRODUCTION_TARGET_GROUP_ARN}', $ProductionTargetGroupArn)
if ($rendered -match '\$\{[A-Z_]+\}') { throw 'Unresolved target-group-binding admission token.' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = Join-Path $OutputDirectory 'target-group-binding-admission.yaml'
Set-Content -LiteralPath $output -Value $rendered -NoNewline
Write-Output $output
