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

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    try { & $Action } catch { return }
    throw "ASSERTION FAILED: $Message"
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
        vpcId = 'vpc_id'; privateSubnetIds = 'private_subnet_ids'; databaseSubnetIds = 'database_subnet_ids'; functionSecurityGroupId = 'function_security_group_id'
        clusterName = 'cluster_name'; clusterOidcProviderArn = 'cluster_oidc_provider_arn'; vpcLinkId = 'vpc_link_id'
        backendListenerArns = 'backend_listener_arns'; codeBuildProjects = 'codebuild_projects'
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

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("oficina-foundation-output-roundtrip-" + [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $commit = 'a' * 40
    $rawTerraformOutput = Join-Path $temp 'foundation-terraform-output.json'
    @{
        vpc_id = @{ value = 'vpc-123' }
        private_subnet_ids = @{ value = @('subnet-private-a', 'subnet-private-b') }
        database_subnet_ids = @{ value = @('subnet-db-a', 'subnet-db-b') }
        function_security_group_id = @{ value = 'sg-functions-123' }
        cluster_name = @{ value = 'oficina-phase3' }
        cluster_oidc_provider_arn = @{ value = 'arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/example' }
        vpc_link_id = @{ value = 'abc123' }
        backend_listener_arns = @{ value = @{ staging = 'arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/oficina-phase3-internal/staging'; production = 'arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/oficina-phase3-internal/production' } }
        codebuild_projects = @{ value = @{ k8s_staging = @{ roleArn = 'arn:aws:iam::123456789012:role/k8s-staging' }; k8s_production = @{ roleArn = 'arn:aws:iam::123456789012:role/k8s-production' } } }
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $rawTerraformOutput -NoNewline
    $receipt = Join-Path $temp 'foundation-output-receipt.json'
    $offline = Join-Path $temp 'offline-artifact-store'
    & (Join-Path $repoRoot 'scripts/publish-foundation-outputs.ps1') -TerraformOutputFile $rawTerraformOutput -SourceCommit $commit -ArtifactBucket 'oficina-artifacts-example' -ReceiptFile $receipt -Offline -OfflineDirectory $offline | Out-Null
    $publishedReceipt = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    Assert-True ($publishedReceipt.artifactKey -eq "releases/k8s/foundation/outputs/$commit.json" -and $publishedReceipt.artifactVersionId -match '^offline-' -and $publishedReceipt.artifactSha256 -match '^[a-f0-9]{64}$') 'publication must retain exact foundation key, immutable version, and digest evidence.'
    Assert-Throws { & (Join-Path $repoRoot 'scripts/export-outputs.ps1') -TerraformOutputFile $rawTerraformOutput -Scope foundation -Environment staging -SourceCommit $commit -OutputFile (Join-Path $temp 'wrong-scope-environment.json') } 'foundation output export must reject a staging environment label.'
    $baseTfvars = Join-Path $temp 'base.tfvars.json'
    @{ aws_region = 'us-east-1'; name = 'oficina-phase3'; functions_outputs = @{ functionArns = @{ authorizer = 'arn:aws:lambda:us-east-1:123456789012:function:authorizer'; challenge = 'arn:aws:lambda:us-east-1:123456789012:function:challenge'; verification = 'arn:aws:lambda:us-east-1:123456789012:function:verification' } }; gateway_allowed_origins = @('https://example.test') } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $baseTfvars -NoNewline
    $resolvedTfvars = Join-Path $temp 'resolved.tfvars.json'
    & (Join-Path $repoRoot 'scripts/resolve-foundation-outputs.ps1') -ArtifactBucket 'oficina-artifacts-example' -ReceiptFile $receipt -BaseTerraformVariablesFile $baseTfvars -OutputTerraformVariablesFile $resolvedTfvars -OfflineDirectory $offline | Out-Null
    $resolved = Get-Content -LiteralPath $resolvedTfvars -Raw | ConvertFrom-Json
    Assert-True ($resolved.foundation_outputs.vpc_id -eq 'vpc-123' -and $resolved.foundation_outputs.vpc_link_id -eq 'abc123' -and $resolved.foundation_outputs.backend_listener_arns.staging -match '/staging$' -and $resolved.foundation_outputs.backend_listener_arns.production -match '/production$' -and $resolved.foundation_outputs.codebuild_projects.k8s_staging.roleArn -match ':role/k8s-staging$') 'verified foundation outputs must produce the exact platform foundation_outputs shape.'
    $artifactFile = Join-Path (Join-Path $offline 'versions') "$($publishedReceipt.artifactVersionId).json"
    $completeArtifactText = Get-Content -LiteralPath $artifactFile -Raw

    foreach ($entry in $expectedMappings.foundation.GetEnumerator()) {
        $missingTerraformOutput = Join-Path $temp "missing-$($entry.Value).json"
        $rawWithoutField = Get-Content -LiteralPath $rawTerraformOutput -Raw | ConvertFrom-Json
        $rawWithoutField.PSObject.Properties.Remove($entry.Value)
        $rawWithoutField | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $missingTerraformOutput -NoNewline
        Assert-Throws { & (Join-Path $repoRoot 'scripts/publish-foundation-outputs.ps1') -TerraformOutputFile $missingTerraformOutput -SourceCommit $commit -ArtifactBucket 'oficina-artifacts-example' -ReceiptFile (Join-Path $temp "missing-$($entry.Value)-receipt.json") -Offline -OfflineDirectory $offline } "export must reject a foundation document without '$($entry.Key)'."

        $missingArtifact = Join-Path $temp "missing-$($entry.Key)-artifact.json"
        $artifactWithoutField = $completeArtifactText | ConvertFrom-Json
        $artifactWithoutField.outputs.PSObject.Properties.Remove($entry.Key)
        $artifactWithoutField | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $missingArtifact -NoNewline
        $missingReceipt = Join-Path $temp "missing-$($entry.Key)-receipt.json"
        $missingReceiptDocument = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
        $missingReceiptDocument.artifactSha256 = (Get-FileHash -LiteralPath $missingArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
        $missingReceiptDocument | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $missingReceipt -NoNewline
        Assert-Throws { & (Join-Path $repoRoot 'scripts/resolve-foundation-outputs.ps1') -ArtifactBucket 'oficina-artifacts-example' -ReceiptFile $missingReceipt -BaseTerraformVariablesFile $baseTfvars -OutputTerraformVariablesFile $resolvedTfvars -ArtifactFileForTest $missingArtifact } "consumer must reject a digest-valid foundation artifact without '$($entry.Key)'."
    }

    $wrongVersionReceipt = Join-Path $temp 'wrong-version-receipt.json'
    $wrongVersion = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    $wrongVersion.artifactVersionId = 'offline-version-that-does-not-exist'
    $wrongVersion | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $wrongVersionReceipt -NoNewline
    Assert-Throws { & (Join-Path $repoRoot 'scripts/resolve-foundation-outputs.ps1') -ArtifactBucket 'oficina-artifacts-example' -ReceiptFile $wrongVersionReceipt -BaseTerraformVariablesFile $baseTfvars -OutputTerraformVariablesFile $resolvedTfvars -OfflineDirectory $offline } 'a receipt with a different immutable artifact version must be rejected.'

    Set-Content -LiteralPath $artifactFile -NoNewline -Value '{"schemaVersion":1,"environment":"foundation","sourceCommit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","outputs":{}}'
    Assert-Throws { & (Join-Path $repoRoot 'scripts/resolve-foundation-outputs.ps1') -ArtifactBucket 'oficina-artifacts-example' -ReceiptFile $receipt -BaseTerraformVariablesFile $baseTfvars -OutputTerraformVariablesFile $resolvedTfvars -OfflineDirectory $offline } 'a tampered foundation artifact must fail its receipt digest check.'

    $schemaArtifact = Join-Path $temp 'schema-mismatch.json'
    $schemaArtifactDocument = $completeArtifactText | ConvertFrom-Json
    $schemaArtifactDocument.schemaVersion = 2
    $schemaArtifactDocument | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $schemaArtifact -NoNewline
    $schemaReceipt = Join-Path $temp 'schema-receipt.json'
    $schema = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    $schema.artifactSha256 = (Get-FileHash -LiteralPath $schemaArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
    $schema | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $schemaReceipt -NoNewline
    Assert-Throws { & (Join-Path $repoRoot 'scripts/resolve-foundation-outputs.ps1') -ArtifactBucket 'oficina-artifacts-example' -ReceiptFile $schemaReceipt -BaseTerraformVariablesFile $baseTfvars -OutputTerraformVariablesFile $resolvedTfvars -ArtifactFileForTest $schemaArtifact } 'a digest-valid schema mismatch must be rejected.'

    $sourceMismatchArtifact = Join-Path $temp 'source-mismatch.json'
    $sourceMismatchDocument = $completeArtifactText | ConvertFrom-Json
    $sourceMismatchDocument.sourceCommit = ('b' * 40)
    $sourceMismatchDocument | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $sourceMismatchArtifact -NoNewline
    $sourceMismatchReceipt = Join-Path $temp 'source-mismatch-receipt.json'
    $sourceMismatch = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    $sourceMismatch.artifactSha256 = (Get-FileHash -LiteralPath $sourceMismatchArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
    $sourceMismatch | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $sourceMismatchReceipt -NoNewline
    Assert-Throws { & (Join-Path $repoRoot 'scripts/resolve-foundation-outputs.ps1') -ArtifactBucket 'oficina-artifacts-example' -ReceiptFile $sourceMismatchReceipt -BaseTerraformVariablesFile $baseTfvars -OutputTerraformVariablesFile $resolvedTfvars -ArtifactFileForTest $sourceMismatchArtifact } 'a digest-valid source commit mismatch must be rejected.'

    $wrongScopeArtifact = Join-Path $temp 'wrong-scope.json'
    @{ schemaVersion = 1; environment = 'staging'; sourceCommit = $commit; outputs = @{ vpcId = 'vpc-123'; clusterName = 'oficina-phase3'; vpcLinkId = 'abc123'; backendListenerArns = @{ staging = 'listener-staging'; production = 'listener-production' }; codeBuildProjects = @{ k8s_staging = @{ roleArn = 'role-staging' }; k8s_production = @{ roleArn = 'role-production' } } } } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $wrongScopeArtifact -NoNewline
    $wrongScopeReceipt = Join-Path $temp 'wrong-scope-receipt.json'
    $wrongScope = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    $wrongScope.artifactSha256 = (Get-FileHash -LiteralPath $wrongScopeArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
    $wrongScope | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $wrongScopeReceipt -NoNewline
    Assert-Throws { & (Join-Path $repoRoot 'scripts/resolve-foundation-outputs.ps1') -ArtifactBucket 'oficina-artifacts-example' -ReceiptFile $wrongScopeReceipt -BaseTerraformVariablesFile $baseTfvars -OutputTerraformVariablesFile $resolvedTfvars -ArtifactFileForTest $wrongScopeArtifact } 'a non-foundation artifact must not supply platform foundation_outputs.'
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output 'PASS: release-readiness handoff matches the reviewed protection, output, ordering, and acceptance boundaries.'
