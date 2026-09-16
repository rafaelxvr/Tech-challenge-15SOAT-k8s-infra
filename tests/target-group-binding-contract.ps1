[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$renderer = Join-Path $repoRoot 'scripts/render-target-group-binding.ps1'
$rbac = Get-Content -LiteralPath (Join-Path $repoRoot 'k8s/platform/base/deployer-rbac.yaml') -Raw
$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("oficina-target-binding-test-" + [guid]::NewGuid())

try {
    $releaseRole = ($rbac -split '---')[0]
    if ($releaseRole -match 'targetgroupbindings') { throw 'Release deployer must not create, patch, or update TargetGroupBindings.' }
    if ($rbac -notmatch 'name: oficina-platform-binding' -or $rbac -notmatch 'resourceNames: \["oficina-app"\]') { throw 'TargetGroupBinding needs its separately bound immutable platform role.' }

    $stagingArn = 'arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/oficina-staging/1234567890abcdef'
    $binding = & $renderer -Environment staging -TargetGroupArn $stagingArn -OutputDirectory $tempDirectory
    $rendered = Get-Content -LiteralPath $binding -Raw
    if ($rendered -notmatch 'namespace: oficina-staging' -or $rendered -notmatch [regex]::Escape($stagingArn)) { throw 'Trusted binding renderer did not keep staging namespace and target group together.' }

    $retargetRejected = $false
    try {
        & $renderer -Environment staging -TargetGroupArn 'arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/oficina-production/abcdef1234567890' -OutputDirectory $tempDirectory | Out-Null
    }
    catch { $retargetRejected = $true }
    if (-not $retargetRejected) { throw 'A staging binding could be retargeted to the production target group.' }

    Write-Output 'PASS: only the trusted platform binder can mutate the named TargetGroupBinding and staging cannot target production.'
}
finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
