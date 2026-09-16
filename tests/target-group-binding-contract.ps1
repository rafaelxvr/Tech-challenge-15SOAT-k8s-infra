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
    $createRole = ($rbac -split '---' | Where-Object { $_ -match 'name: oficina-platform-binding-create' }) -join "`n"
    $mutateRole = ($rbac -split '---' | Where-Object { $_ -match 'name: oficina-platform-binding-mutate' }) -join "`n"
    if ($createRole -notmatch 'verbs: \["create"\]' -or $createRole -match 'resourceNames:') { throw 'TargetGroupBinding create must be separately granted without resourceNames because Kubernetes cannot authorize create by name.' }
    if ($mutateRole -notmatch 'resourceNames: \["oficina-app"\]' -or $mutateRole -notmatch 'verbs: \["get", "patch", "update"\]' -or $mutateRole -match '"create"') { throw 'TargetGroupBinding get/patch/update must stay name-limited to oficina-app.' }

    $stagingArn = 'arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/oficina-staging-app/1234567890abcdef'
    $binding = & $renderer -Environment staging -TargetGroupArn $stagingArn -OutputDirectory $tempDirectory
    $rendered = Get-Content -LiteralPath $binding -Raw
    if ($rendered -notmatch 'namespace: oficina-staging' -or $rendered -notmatch [regex]::Escape($stagingArn)) { throw 'Trusted binding renderer did not keep staging namespace and target group together.' }
    if ($rendered -notmatch 'app.kubernetes.io/managed-by: oficina-k8s-infra' -or $rendered -notmatch 'oficina.io/managed-by: platform-binding') { throw 'Trusted binding renderer did not retain the required managed-by labels.' }

    $retargetRejected = $false
    try {
        & $renderer -Environment staging -TargetGroupArn 'arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/oficina-production-app/abcdef1234567890' -OutputDirectory $tempDirectory | Out-Null
    }
    catch { $retargetRejected = $true }
    if (-not $retargetRejected) { throw 'A staging binding could be retargeted to the production target group.' }

    foreach ($injectedArn in @(
        "$stagingArn' || true || '",
        "$stagingArn; object.spec.targetGroupARN == 'anything'",
        "$stagingArn`napiVersion: v1"
    )) {
        $injectionRejected = $false
        try { & $renderer -Environment staging -TargetGroupArn $injectedArn -OutputDirectory $tempDirectory | Out-Null }
        catch { $injectionRejected = $true }
        if (-not $injectionRejected) { throw 'TargetGroupBinding renderer accepted an ARN containing CEL or YAML injection syntax.' }
    }

    Write-Output 'PASS: only the trusted platform binder can mutate the named TargetGroupBinding and staging cannot target production.'
}
finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
