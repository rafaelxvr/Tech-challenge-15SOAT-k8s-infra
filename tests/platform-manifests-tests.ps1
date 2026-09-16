[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$renderer = Join-Path $repoRoot 'scripts/render-platform.ps1'
$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("oficina-platform-test-" + [guid]::NewGuid())
$image = '123456789012.dkr.ecr.us-east-1.amazonaws.com/oficina-app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$role = 'arn:aws:iam::123456789012:role/oficina-app-staging'
$deployer = 'arn:aws:iam::123456789012:role/oficina-k8s-staging-deploy'
$platformBinder = 'arn:aws:iam::123456789012:role/oficina-platform-binding'
$secret = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/app-AbCdEf'
$ingestSecret = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-AbCdEf'

function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) {
    if (-not $Text.Contains($Expected)) { throw $Message }
}

try {
    foreach ($environment in @('staging', 'production')) {
        $environmentIngest = $ingestSecret -replace '/staging/', ("/" + $environment + "/")
        $file = & $renderer -Environment $environment -Image $image -AppIrsaRoleArn $role -DeployerPrincipalArn $deployer -PlatformBindingPrincipalArn $platformBinder -DbHost 'db.oficina.internal' -DbCidr '10.20.0.0/24' -AlbSubnetCidrOne '10.42.0.0/24' -AlbSubnetCidrTwo '10.42.1.0/24' -AppSecretArn $secret -NewRelicIngestSecretArn $environmentIngest -NewRelicAccountId '1234567' -OutputDirectory $tempDirectory
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
        Assert-Contains $manifest 'OBSERVABILITY_SNAPSHOTS_ENABLED' 'Cloud workload must opt into bounded snapshots.'
        Assert-Contains $manifest ('value: ' + $environment) 'Snapshot environment must be nonsecret and environment-specific.'
        Assert-Contains $manifest 'name: OFICINA_ENVIRONMENT' 'JSON logs must use the same finite environment label as telemetry.'
        Assert-Contains $manifest 'newrelic_insert_key' 'Snapshot exporter must reference the existing CSI-synced ingest key.'
        Assert-Contains $manifest 'name: NEW_RELIC_LICENSE_KEY' 'The pinned Java agent must consume the existing CSI-synced ingest key.'
        Assert-Contains $manifest 'name: oficina-runtime-secrets' 'The Java agent must use the approved runtime Secret reference.'
        Assert-Contains $manifest $environmentIngest 'Only the approved environment ingest-secret ARN may be rendered.'
        if ($manifest -match 'NEW_RELIC_API_KEY') { throw 'Provider API credentials must never reach an application workload.' }
        Assert-Contains $manifest 'default-deny-ingress-egress' 'Namespace needs default deny ingress and egress.'
        Assert-Contains $manifest 'port: 5432' 'App network policy must restrict database traffic to PostgreSQL.'
        Assert-Contains $manifest ('oficina.io/environment: ' + $environment) 'App traffic must allow only the same environment namespace.'
        Assert-Contains $manifest 'cidr: 10.42.0.0/24' 'ALB ingress must use the first dedicated source subnet, not all VPC traffic.'
        Assert-Contains $manifest 'cidr: 10.42.1.0/24' 'ALB ingress must use the second dedicated source subnet, not all VPC traffic.'
        if ($manifest.Contains('cidr: 10.0.0.0/16')) { throw 'App ingress must not admit every source in the VPC.' }
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

    $crossEnvironmentIngestRejected = $false
    try {
        & $renderer -Environment staging -Image $image -AppIrsaRoleArn $role -DeployerPrincipalArn $deployer -PlatformBindingPrincipalArn $platformBinder -DbHost 'db.oficina.internal' -DbCidr '10.20.0.0/24' -AlbSubnetCidrOne '10.42.0.0/24' -AlbSubnetCidrTwo '10.42.1.0/24' -AppSecretArn $secret -NewRelicIngestSecretArn ($ingestSecret -replace '/staging/', '/production/') -NewRelicAccountId '1234567' -OutputDirectory $tempDirectory | Out-Null
    }
    catch { $crossEnvironmentIngestRejected = $true }
    if (-not $crossEnvironmentIngestRejected) { throw 'Renderer accepted a cross-environment New Relic ingest-secret reference.' }

    if ($staging -notmatch 'oficina.io/environment: staging' -or $production -notmatch 'oficina.io/environment: production') { throw 'Rendered policy did not retain environment-specific namespace isolation.' }
    Write-Output 'PASS: rendered platform manifests enforce bounded workload capacity, target binding, and environment-specific policies.'
}
finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
