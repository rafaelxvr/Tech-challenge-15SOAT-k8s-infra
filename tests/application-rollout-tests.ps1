[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$renderer = Join-Path $repoRoot 'scripts/render-platform.ps1'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('oficina-i6-' + [guid]::NewGuid())
$checks = 0
function Assert-Match([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -cnotmatch $Pattern) { throw $Message }
    $script:checks++
}
try {
    foreach ($environment in @('staging', 'production')) {
        $inputs = @{
            Environment = $environment
            Image = '123456789012.dkr.ecr.us-east-1.amazonaws.com/oficina-app@sha256:' + ('a' * 64)
            AppIrsaRoleArn = "arn:aws:iam::123456789012:role/oficina-phase3-$environment-app"
            DeployerPrincipalArn = "arn:aws:iam::123456789012:role/oficina-$environment-deploy"
            PlatformBindingPrincipalArn = 'arn:aws:iam::123456789012:role/oficina-platform-binding'
            DbHost = 'db.oficina.internal'
            DbCidr = '10.20.0.0/24'
            AlbSubnetCidrOne = '10.42.0.0/24'
            AlbSubnetCidrTwo = '10.42.1.0/24'
            AppSecretArn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/$environment/app-AbCdEf"
            AuthorizerTrustSecretArn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/$environment/authorizer-trust-AbCdEf"
            NewRelicIngestSecretArn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/$environment/newrelic-ingest-AbCdEf"
            NewRelicAccountId = '1234567'
            OutputDirectory = $scratch
        }
        $rendered = Get-Content -LiteralPath (& $renderer @inputs) -Raw
        $deployment = ($rendered -split '(?m)^---\s*$' | Where-Object { $_ -match '(?m)^kind: Deployment$' }) -join ''
        Assert-Match $deployment 'name: SPRING_FLYWAY_ENABLED\s+value: "false"' 'Cloud Flyway must be explicitly disabled.'
        Assert-Match $deployment 'name: SPRING_JPA_HIBERNATE_DDL_AUTO\s+value: validate' 'Hibernate may validate but cannot mutate schema.'
        Assert-Match $deployment 'name: SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE\s+value: "5"' 'Pool size must be exactly five.'
        Assert-Match $deployment 'limits:\s+cpu: "1"\s+memory: 1Gi\s+requests:\s+cpu: 250m\s+memory: 768Mi' 'Capacity must be bounded per app container.'
        foreach ($probe in @('startupProbe', 'livenessProbe', 'readinessProbe')) {
            $group = if ($probe -eq 'readinessProbe') { 'readiness' } else { 'liveness' }
            Assert-Match $deployment ($probe + ':\s+(?:[^\n]+\n)*?\s+path: /api/actuator/health/' + $group) "Missing separate $probe health group."
        }
        Assert-Match $deployment 'name: JWT_SECRET\s+valueFrom:\s+secretKeyRef:\s+key: staff_hmac_secret\s+name: oficina-staff-jwt' 'Staff signing secret must be a distinct Secret reference.'
        Assert-Match $deployment 'name: SPRING_CONFIG_ADDITIONAL_LOCATION\s+value: file:/etc/oficina/public/customer-public-keys.yaml' 'Customer verification keys require a public configuration file.'
        Assert-Match $deployment 'sslmode=verify-full&sslrootcert=/etc/oficina/public/rds-ca.pem' 'Database TLS must verify the host against a mounted CA.'
        Assert-Match $deployment 'jdbc:postgresql://db.oficina.internal:5432/oficina\?' 'Database name must match the DB output contract.'
        Assert-Match $deployment ("name: oficina-runtime-public-$environment") 'Runtime public configuration must remain environment-scoped.'
        Assert-Match $deployment 'name: OUTBOX_ENABLED\s+value: "true"' 'Cloud outbox must be enabled.'
        Assert-Match $deployment 'key: notification-queue-url' 'Outbox queue must come from reviewed outputs.'
        Assert-Match $rendered 'averageUtilization: 60' 'HPA CPU target must be 60 percent.'
        Assert-Match $rendered 'path: "STAFF_HMAC_SECRET"' 'CSI must project only the staff HMAC from the existing trust bundle.'
        if ($deployment -match 'PRIVATE KEY|CUSTOMER_PRIVATE|customer-signing|initContainers:|optional: true' -or $rendered -match '(?m)^stringData:') { throw 'Workload contains signing material, migrations, optional trust or plaintext secrets.' }
        $checks++
        if ($environment -eq 'staging' -and $rendered -match 'kind: PodDisruptionBudget') { throw 'Staging must not inherit the production PDB.' }

        $other = if ($environment -eq 'staging') { 'production' } else { 'staging' }
        foreach ($key in @('AppSecretArn', 'AuthorizerTrustSecretArn', 'NewRelicIngestSecretArn', 'AppIrsaRoleArn')) {
            $invalid = @{} + $inputs
            $invalid[$key] = $inputs[$key].Replace($environment, $other)
            $rejected = $false
            try { & $renderer @invalid | Out-Null } catch { $rejected = $true }
            if (-not $rejected) { throw "Accepted cross-environment $key." }
            $checks++
        }
        foreach ($case in @(
            @{Key='Image'; Value='oficina-app:latest'},
            @{Key='Image'; Value=("bad`n" + $inputs.Image)},
            @{Key='DbHost'; Value="db.internal`nmalicious: true"},
            @{Key='AuthorizerTrustSecretArn'; Value=$inputs.AuthorizerTrustSecretArn.Replace('123456789012', '999999999999')},
            @{Key='AuthorizerTrustSecretArn'; Value=$inputs.AuthorizerTrustSecretArn.Replace('authorizer-trust', 'customer-signing')}
        )) {
            $invalid = @{} + $inputs
            $invalid[$case.Key] = $case.Value
            $rejected = $false
            try { & $renderer @invalid | Out-Null } catch { $rejected = $true }
            if (-not $rejected) { throw "Accepted invalid $($case.Key)." }
            $checks++
        }
    }
    Write-Output "PASS: $checks application rollout assertions across both environments."
}
finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    if (-not $resolvedScratch.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolvedScratch) { Remove-Item -LiteralPath $resolvedScratch -Recurse -Force }
}
