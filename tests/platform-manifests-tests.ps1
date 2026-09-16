[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$renderer = Join-Path $repoRoot 'scripts/render-platform.ps1'
$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("oficina-platform-test-" + [guid]::NewGuid())
$image = '123456789012.dkr.ecr.us-east-1.amazonaws.com/oficina-app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$targetGroup = 'arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/oficina-staging/1234567890abcdef'
$role = 'arn:aws:iam::123456789012:role/oficina-app-staging'
$deployer = 'arn:aws:iam::123456789012:role/oficina-k8s-staging-deploy'
$secret = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/app-AbCdEf'

function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) {
    if (-not $Text.Contains($Expected)) { throw $Message }
}

try {
    foreach ($environment in @('staging', 'production')) {
        $file = & $renderer -Environment $environment -Image $image -TargetGroupArn $targetGroup -AppIrsaRoleArn $role -DeployerPrincipalArn $deployer -DbHost 'db.oficina.internal' -DbCidr '10.20.0.0/24' -VpcCidr '10.0.0.0/16' -AppSecretArn $secret -OutputDirectory $tempDirectory
        $manifest = Get-Content -LiteralPath $file -Raw
        if ($manifest -match '\$\{[A-Z_]+\}') { throw "Rendered $environment manifest still has deployment tokens." }
        Assert-Contains $manifest "name: oficina-$environment" "Expected isolated $environment namespace."
        Assert-Contains $manifest 'automountServiceAccountToken: false' 'Workload must not mount the Kubernetes API token by default.'
        Assert-Contains $manifest 'cpu: 250m' 'App request must remain 250m.'
        Assert-Contains $manifest 'memory: 768Mi' 'App request must remain 768Mi.'
        Assert-Contains $manifest 'memory: 1Gi' 'App limit must remain 1Gi.'
        Assert-Contains $manifest 'SPRING_FLYWAY_ENABLED' 'Cloud workload must explicitly disable automatic Flyway migration.'
        Assert-Contains $manifest '/api/actuator/health/liveness' 'Startup and liveness probes must use the liveness group.'
        Assert-Contains $manifest '/api/actuator/health/readiness' 'Readiness and target health must use the readiness group.'
        Assert-Contains $manifest 'SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE' 'Hikari must remain capped at five connections.'
        Assert-Contains $manifest 'value: "5"' 'Hikari max must be five.'
        Assert-Contains $manifest 'targetGroupARN: arn:aws:elasticloadbalancing' 'TargetGroupBinding must consume only the platform target group.'
        Assert-Contains $manifest 'default-deny-ingress-egress' 'Namespace needs default deny ingress and egress.'
        Assert-Contains $manifest 'port: 5432' 'App network policy must restrict database traffic to PostgreSQL.'
        if ($manifest -match 'stringData:') { throw 'Rendered platform manifest must not contain plaintext secret values.' }
    }

    $staging = Get-Content -LiteralPath (Join-Path $tempDirectory 'platform-staging.yaml') -Raw
    $production = Get-Content -LiteralPath (Join-Path $tempDirectory 'platform-production.yaml') -Raw
    Assert-Contains $staging 'minReplicas: 1' 'Staging HPA minimum must be one.'
    Assert-Contains $staging 'maxReplicas: 2' 'Staging HPA maximum must be two.'
    Assert-Contains $production 'minReplicas: 2' 'Production HPA minimum must be two.'
    Assert-Contains $production 'maxReplicas: 4' 'Production HPA maximum must be four.'
    Assert-Contains $production 'kind: PodDisruptionBudget' 'Production requires a PDB.'
    Assert-Contains $production 'minAvailable: 1' 'Production PDB minimum availability must be one.'

    Write-Output 'PASS: platform manifests render with bounded workload capacity, probes, RBAC, target binding, and namespace isolation.'
}
finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
