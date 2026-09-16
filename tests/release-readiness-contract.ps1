[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Contains([string]$Text, [string]$Needle, [string]$Message) {
    Assert-True $Text.Contains($Needle) $Message
}

function Get-TerraformOutputNames([string]$Path) {
    return @(Select-String -LiteralPath $Path -Pattern '^output\s+"([^"]+)"' | ForEach-Object { $_.Matches[0].Groups[1].Value })
}

$handoff = Join-Path $repoRoot 'docs/release-readiness.md'
$sequence = Join-Path $repoRoot 'docs/deployment-sequence.md'
$allowlistPath = Join-Path $repoRoot 'contracts/outputs-allowlist.json'

Assert-True (Test-Path -LiteralPath $handoff -PathType Leaf) 'release-readiness handoff must exist.'
Assert-True (Test-Path -LiteralPath $sequence -PathType Leaf) 'deployment sequence runbook must exist.'
Assert-True (Test-Path -LiteralPath $allowlistPath -PathType Leaf) 'output allowlist must exist.'

$text = Get-Content -LiteralPath $handoff -Raw
foreach ($required in @(
    'No cloud deployment has been performed from this repository.',
    'develop` protection',
    'main` protection',
    '`staging` environment',
    '`production` environment',
    'aud=sts.amazonaws.com',
    'scripts/check-cloud-window.ps1',
    'conditional creation',
    'K8S staging/production, DB staging/production, Functions staging/production, and APP staging/production',
    'S3 VersionId',
    'terraform destroy'
)) {
    Assert-Contains $text $required "release-readiness handoff must document '$required'."
}

foreach ($relativePath in @('deployment-sequence.md', 'bootstrap.md', 'platform-workloads.md', '../contracts/outputs-allowlist.json')) {
    $path = Join-Path (Split-Path -Parent $handoff) $relativePath
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "release-readiness link target '$relativePath' must exist."
}

try { $allowlist = Get-Content -LiteralPath $allowlistPath -Raw | ConvertFrom-Json }
catch { throw 'ASSERTION FAILED: output allowlist must be valid JSON.' }
Assert-True ($allowlist.schemaVersion -eq 1) 'output allowlist must retain schema version 1.'
Assert-True ($allowlist.repository -eq 'oficina-k8s-infra') 'output allowlist must remain owned by this repository.'

$expectedMappings = [ordered]@{
    foundation = [ordered]@{
        vpcId = 'vpc_id'; privateSubnetIds = 'private_subnet_ids'; databaseSubnetIds = 'database_subnet_ids'
        clusterName = 'cluster_name'; clusterOidcProviderArn = 'cluster_oidc_provider_arn'; codeBuildProjects = 'codebuild_projects'
    }
    environment = [ordered]@{
        apiId = 'api_id'; backendIntegrationId = 'backend_integration_id'; healthIntegrationId = 'health_integration_id'
        targetGroupArn = 'target_group_arn'; listenerArn = 'listener_arn'; namespace = 'namespace'
    }
}

$outputRoots = @{
    foundation = @(Join-Path $repoRoot 'infra/foundation/outputs.tf')
    environment = @(
        (Join-Path $repoRoot 'infra/environments/staging/outputs.tf'),
        (Join-Path $repoRoot 'infra/environments/production/outputs.tf')
    )
}

foreach ($scope in $expectedMappings.Keys) {
    $scopeValue = $allowlist.scopes.PSObject.Properties[$scope]
    Assert-True ($null -ne $scopeValue) "allowlist must define '$scope'."
    $actual = $scopeValue.Value
    foreach ($entry in $expectedMappings[$scope].GetEnumerator()) {
        $property = $actual.PSObject.Properties[$entry.Key]
        Assert-True ($null -ne $property -and [string]$property.Value -eq $entry.Value) "allowlist '$scope/$($entry.Key)' must map to '$($entry.Value)'."
        Assert-True ($entry.Key -notmatch '(?i)(secret|password|credential|token|state|master)') "published field '$($entry.Key)' must not be sensitive."
        Assert-True ($entry.Value -notmatch '(?i)(secret|password|credential|token|state|master)') "Terraform output '$($entry.Value)' must not be sensitive."
        foreach ($root in $outputRoots[$scope]) {
            Assert-True ((Get-TerraformOutputNames $root) -contains $entry.Value) "allowlisted '$scope/$($entry.Value)' must exist in '$root'."
        }
    }
    $actualNames = @($actual.PSObject.Properties.Name | Sort-Object)
    $expectedNames = @($expectedMappings[$scope].Keys | Sort-Object)
    Assert-True (($actualNames -join ',') -eq ($expectedNames -join ',')) "allowlist '$scope' must not add an undocumented output."
}

Write-Output 'PASS: release-readiness handoff matches the reviewed protection, output, ordering, and acceptance boundaries.'
