[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$renderer = Join-Path $repoRoot 'scripts/render-platform.ps1'
. (Join-Path $repoRoot 'scripts/platform-manifest-contract.ps1')
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
        $databaseCidrs = if ($environment -ceq 'staging') { @('10.42.64.0/24', '10.42.65.0/24') } else { @('10.20.0.0/24') }
        $file = & $renderer -Environment $environment -Image $image -AppIrsaRoleArn ($role -replace 'staging', $environment) -DeployerPrincipalArn $deployer -PlatformBindingPrincipalArn $platformBinder -DbHost 'db.oficina.internal' -DbCidr $databaseCidrs -AlbSubnetCidrOne '10.42.0.0/24' -AlbSubnetCidrTwo '10.42.1.0/24' -AppSecretArn ($secret -replace '/staging/', "/$environment/") -AuthorizerTrustSecretArn "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/$environment/authorizer-trust-AbCdEf" -NewRelicIngestSecretArn $environmentIngest -NewRelicAccountId '1234567' -OutputDirectory $tempDirectory
        $manifest = Get-Content -LiteralPath $file -Raw
        $documents = Read-PlatformManifest $file
        $policy = @($documents | Where-Object { $_.kind -ceq 'NetworkPolicy' -and $_.metadata.name -ceq 'oficina-app-allow-required-paths' })[0]
        $databaseRule = @($policy.spec.egress | Where-Object { $_.ports[0].port -eq 5432 })[0]
        if (($databaseRule.to.ipBlock.cidr -join ',') -cne ($databaseCidrs -join ',') -or $databaseRule.ports.Count -ne 1 -or $databaseRule.ports[0].protocol -cne 'TCP') { throw 'Database egress must be exactly the supplied subnet union on TCP/5432.' }
        foreach ($peer in @($policy.spec.egress[0].to[0], $policy.spec.ingress[0].from[3])) {
            if (($peer.namespaceSelector.matchLabels.PSObject.Properties.Name -join ',') -cne 'kubernetes.io/metadata.name' -or $peer.namespaceSelector.matchLabels.'kubernetes.io/metadata.name' -cne 'kube-system') { throw 'System peers must select only the kube-system namespace.' }
            if (($peer.podSelector.matchLabels.PSObject.Properties.Name -join ',') -cne 'k8s-app') { throw 'System peer selectors must not require oficina ownership labels.' }
        }
        if ($policy.spec.egress[0].to[0].podSelector.matchLabels.'k8s-app' -cne 'kube-dns' -or $policy.spec.ingress[0].from[3].podSelector.matchLabels.'k8s-app' -cne 'metrics-server') { throw 'System peers must preserve DNS and metrics-server names.' }
        if (($policy.spec.egress[0].ports | ForEach-Object { "$($_.protocol)/$($_.port)" }) -join ',' -cne 'UDP/53,TCP/53') { throw 'DNS must retain exactly UDP and TCP port 53.' }
        if ($policy.spec.ingress[0].ports.Count -ne 1 -or $policy.spec.ingress[0].ports[0].port -ne 8080 -or $policy.spec.ingress[0].ports[0].protocol -cne 'TCP') { throw 'Metrics and APP ingress must retain TCP/8080 only.' }
        $deny = @($documents | Where-Object { $_.kind -ceq 'NetworkPolicy' -and $_.metadata.name -ceq 'default-deny-ingress-egress' })[0]
        if (@($deny.spec.podSelector.PSObject.Properties).Count -ne 0 -or ($deny.spec.policyTypes -join ',') -cne 'Ingress,Egress') { throw 'Default deny must still cover the entire namespace in both directions.' }
        foreach ($selector in @($policy.spec.podSelector.matchLabels, $policy.spec.ingress[0].from[2].podSelector.matchLabels)) {
            if ($selector.'app.kubernetes.io/name' -cne 'oficina-app' -or $selector.'app.kubernetes.io/part-of' -cne 'oficina' -or $selector.'app.kubernetes.io/managed-by' -cne 'oficina-k8s-infra') { throw 'APP selectors must retain their existing scope.' }
        }
        $deployment = @($documents | Where-Object kind -CEQ 'Deployment')[0]
        $service = @($documents | Where-Object kind -CEQ 'Service')[0]
        foreach ($selector in @($deployment.spec.selector.matchLabels, $deployment.spec.template.metadata.labels, $service.spec.selector)) {
            if ($selector.'app.kubernetes.io/name' -cne 'oficina-app' -or $selector.'app.kubernetes.io/part-of' -cne 'oficina' -or $selector.'app.kubernetes.io/managed-by' -cne 'oficina-k8s-infra') { throw 'Existing Deployment/Service selectors and pod labels must remain compatible.' }
        }
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

    $environment = 'staging'
    foreach ($invalidCidrs in @(
        @{ Value = @('10.42.64.0/24', '10.42.64.0/24') },
        @{ Value = @('10.42.64.0/24', '999.42.65.0/24') },
        @{ Value = @('10.42.64.0/24', '10.42.65.0/33') },
        @{ Value = @('10.42.64.0/24', "10.42.65.0/24`nmalicious: value") },
        @{ Value = @() },
        @{ Value = $null }
    )) {
        $rejected = $false
        try {
            & $renderer -Environment staging -Image $image -AppIrsaRoleArn $role -DeployerPrincipalArn $deployer -PlatformBindingPrincipalArn $platformBinder -DbHost 'db.oficina.internal' -DbCidr $invalidCidrs.Value -AlbSubnetCidrOne '10.42.0.0/24' -AlbSubnetCidrTwo '10.42.1.0/24' -AppSecretArn $secret -AuthorizerTrustSecretArn 'arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/authorizer-trust-AbCdEf' -NewRelicIngestSecretArn $ingestSecret -NewRelicAccountId '1234567' -OutputDirectory $tempDirectory | Out-Null
        } catch { $rejected = $true }
        if (-not $rejected) { throw 'Renderer accepted duplicate, invalid, empty or injectable database CIDRs.' }
    }
    $crossEnvironmentIngestRejected = $false
    try {
        & $renderer -Environment staging -Image $image -AppIrsaRoleArn ($role -replace 'staging', $environment) -DeployerPrincipalArn $deployer -PlatformBindingPrincipalArn $platformBinder -DbHost 'db.oficina.internal' -DbCidr $databaseCidrs -AlbSubnetCidrOne '10.42.0.0/24' -AlbSubnetCidrTwo '10.42.1.0/24' -AppSecretArn ($secret -replace '/staging/', "/$environment/") -AuthorizerTrustSecretArn "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/$environment/authorizer-trust-AbCdEf" -NewRelicIngestSecretArn ($ingestSecret -replace '/staging/', '/production/') -NewRelicAccountId '1234567' -OutputDirectory $tempDirectory | Out-Null
    }
    catch { $crossEnvironmentIngestRejected = $true }
    if (-not $crossEnvironmentIngestRejected) { throw 'Renderer accepted a cross-environment New Relic ingest-secret reference.' }

    if ($staging -notmatch 'oficina.io/environment: staging' -or $production -notmatch 'oficina.io/environment: production') { throw 'Rendered policy did not retain environment-specific namespace isolation.' }
    Write-Output 'PASS: rendered platform manifests enforce bounded workload capacity, target binding, and environment-specific policies.'
}
finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
