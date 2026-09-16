[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('staging', 'production')] [string]$Environment,
    [Parameter(Mandatory)] [string]$TargetGroupArn,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [regex]::IsMatch($TargetGroupArn, "\Aarn:aws:elasticloadbalancing:us-east-1:[0-9]{12}:targetgroup/oficina-phase3-$Environment-app/[0-9a-f]{16}\z")) {
    throw "TargetGroupArn must be the exact reviewed oficina-phase3-$Environment-app target group ARN."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$template = Get-Content -LiteralPath (Join-Path $repoRoot 'k8s/platform/binding/target-group-binding.yaml') -Raw
$rendered = $template.Replace('${ENVIRONMENT}', $Environment).Replace('${TARGET_GROUP_ARN}', $TargetGroupArn)
if ($rendered -match '\$\{[A-Z_]+\}') { throw 'Unresolved target-binding token.' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = Join-Path $OutputDirectory "target-group-binding-$Environment.yaml"
Set-Content -LiteralPath $output -Value $rendered -NoNewline
Write-Output $output
