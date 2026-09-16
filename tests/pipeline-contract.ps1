[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("oficina-pipeline-contract-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp -Force | Out-Null

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Assert-Contains([string]$Text, [string]$Needle, [string]$Message) { Assert-True $Text.Contains($Needle) $Message }
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    try { & $Action } catch { return }
    throw "ASSERTION FAILED: $Message"
}

try {
    & (Join-Path $repoRoot 'tests/executor-bootstrap-harness.ps1') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'ASSERTION FAILED: rendered CodeBuild bootstrap harness failed.' }

    $now = [datetime]::UtcNow
    $evidence = Join-Path $temp 'window.json'
    [ordered]@{
        windowStartUtc = $now.AddMinutes(-2).ToString('o'); windowEndUtc = $now.AddMinutes(30).ToString('o'); recordedAtUtc = $now.ToString('o')
        accountEvidenceReference = 'reviewed-study-account-evidence'; projectAllowanceUsd = 80; reserveUsd = 20; currentEstimatedSpendUsd = 0
    } | ConvertTo-Json | Set-Content -LiteralPath $evidence -NoNewline
    & (Join-Path $repoRoot 'scripts/check-cloud-window.ps1') -EvidenceFile $evidence | Out-Null
    $closed = Get-Content -LiteralPath $evidence -Raw | ConvertFrom-Json
    $closed.windowEndUtc = $now.AddMinutes(-1).ToString('o')
    $closed | ConvertTo-Json | Set-Content -LiteralPath $evidence -NoNewline
    Assert-Throws { & (Join-Path $repoRoot 'scripts/check-cloud-window.ps1') -EvidenceFile $evidence } 'closed windows must reject a launch.'

    $lockDirectory = Join-Path $temp 'locks'
    $tokenA = [guid]::NewGuid().ToString(); $tokenB = [guid]::NewGuid().ToString()
    $lock = Join-Path $repoRoot 'scripts/deployment-lock.ps1'
    & $lock -Action Acquire -StateBucket 'oficina-state-example' -OwnerToken $tokenA -Offline -OfflineDirectory $lockDirectory | Out-Null
    Assert-Throws { & $lock -Action Acquire -StateBucket 'oficina-state-example' -OwnerToken $tokenB -Offline -OfflineDirectory $lockDirectory } 'a concurrent shared mutation must be rejected.'
    Assert-Throws { & $lock -Action Release -StateBucket 'oficina-state-example' -OwnerToken $tokenB -Offline -OfflineDirectory $lockDirectory } 'a non-owner must never release an active lock.'
    Assert-True (@(Get-ChildItem -LiteralPath $lockDirectory -File).Count -eq 1) 'a rejected release must retain the owner lock.'
    & $lock -Action Release -StateBucket 'oficina-state-example' -OwnerToken $tokenA -Offline -OfflineDirectory $lockDirectory | Out-Null
    Assert-True (@(Get-ChildItem -LiteralPath $lockDirectory -File -ErrorAction SilentlyContinue).Count -eq 0) 'the owner can release its own lock.'

    $outputs = Join-Path $temp 'terraform-output.json'
    @{ vpc_id = @{ value = 'vpc-123' }; private_subnet_ids = @{ value = @('subnet-a', 'subnet-b') }; database_subnet_ids = @{ value = @('subnet-db') }; function_security_group_id = @{ value = 'sg-functions-123' }; cluster_name = @{ value = 'oficina-phase3' }; cluster_oidc_provider_arn = @{ value = 'arn:aws:iam::123456789012:oidc-provider/example' }; vpc_link_id = @{ value = 'vpclink-example' }; backend_listener_arns = @{ value = @{ staging = 'listener-staging'; production = 'listener-production' } }; codebuild_projects = @{ value = @{ k8s_staging = @{ roleArn = 'arn:aws:iam::123456789012:role/k8s-staging' }; k8s_production = @{ roleArn = 'arn:aws:iam::123456789012:role/k8s-production' } } }; master_secret_arn = @{ value = 'must-not-export' } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outputs -NoNewline
    $published = Join-Path $temp 'outputs.v1.json'
    & (Join-Path $repoRoot 'scripts/export-outputs.ps1') -TerraformOutputFile $outputs -Scope foundation -Environment foundation -SourceCommit ('a' * 40) -OutputFile $published | Out-Null
    $document = Get-Content -LiteralPath $published -Raw | ConvertFrom-Json
    Assert-True ($document.schemaVersion -eq 1 -and $document.outputs.vpcId -eq 'vpc-123') 'only mapped outputs must be exported in schema v1.'
    Assert-True ($null -eq $document.outputs.PSObject.Properties['masterSecretArn']) 'secret/state-like output names must not appear in an exported document.'
    $badAllowlist = Join-Path $temp 'bad-allowlist.json'
    @{ schemaVersion = 1; repository = 'oficina-k8s-infra'; scopes = @{ foundation = @{ masterSecretArn = 'master_secret_arn' } } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $badAllowlist -NoNewline
    Assert-Throws { & (Join-Path $repoRoot 'scripts/export-outputs.ps1') -TerraformOutputFile $outputs -Scope foundation -Environment foundation -SourceCommit ('a' * 40) -AllowlistFile $badAllowlist -OutputFile $published } 'allowlists containing secret/state fields must be rejected.'

    $bundle = Join-Path $temp 'bundle.zip'; [System.IO.File]::WriteAllBytes($bundle, [byte[]](1, 2, 3, 4))
    $tfvars = Join-Path $temp 'terraform.tfvars.json'; '{}' | Set-Content -LiteralPath $tfvars -NoNewline
    $sourceSha = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = Join-Path $temp 'release-manifest.json'
    @{ schemaVersion = 1; environment = 'staging'; sourceCommit = ('a' * 40); artifactSha256 = $sourceSha; deployerImageDigest = ('sha256:' + ('b' * 64)); contractVersion = 'phase3-v2'; migrationVersion = 'platform-v1'; promotedFromStaging = $false } | ConvertTo-Json | Set-Content -LiteralPath $manifest -NoNewline
    $manifestSha = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
    $openEvidence = Join-Path $temp 'open-window.json'
    [ordered]@{ windowStartUtc = $now.AddMinutes(-2).ToString('o'); windowEndUtc = $now.AddMinutes(30).ToString('o'); recordedAtUtc = $now.ToString('o'); accountEvidenceReference = 'reviewed-study-account-evidence'; projectAllowanceUsd = 80; reserveUsd = 20; currentEstimatedSpendUsd = 0 } | ConvertTo-Json | Set-Content -LiteralPath $openEvidence -NoNewline
    & (Join-Path $repoRoot 'scripts/start-deploy.ps1') -Environment staging -SourceZip $bundle -ExpectedSha256 $sourceSha -ReleaseManifest $manifest -ExpectedManifestSha256 $manifestSha -Bucket 'oficina-artifacts-example' -SourcePrefix 'releases/k8s/staging' -ProjectName 'oficina-phase3-oficina-k8s-infra-staging-deploy' -DeployerImageDigest ('b' * 64) -SourceCommit ('a' * 40) -CloudWindowEvidenceFile $openEvidence -TerraformVariablesFile $tfvars -DryRun | Out-Null
    & (Join-Path $repoRoot 'scripts/deploy.ps1') -Environment staging -ReleaseManifest $manifest -ExpectedSourceSha256 $sourceSha -ExpectedManifestSha256 $manifestSha -SourceCommit ('a' * 40) -ExpectedDeployerImageDigest ('sha256:' + ('b' * 64)) -TerraformVariablesFile $tfvars -TerraformBackendBucket 'oficina-state-example' -TerraformBackendKey 'environments/staging.tfstate' -TerraformBackendLockKey 'environments/staging.tfstate.tflock' -TerraformBackendRegion 'us-east-1' -DryRun | Out-Null
    $backendOverrideNames = @('TERRAFORM_BACKEND_BUCKET', 'TERRAFORM_BACKEND_KEY', 'TERRAFORM_BACKEND_LOCK_KEY', 'TERRAFORM_BACKEND_REGION')
    $backendOverrideOriginal = @{}
    foreach ($name in $backendOverrideNames) { $backendOverrideOriginal[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        # This simulates StartBuild environmentVariablesOverride values. The
        # bootstrap provides explicit reviewed arguments, so these values never
        # select the backend that deploy.ps1 validates before Terraform init.
        $env:TERRAFORM_BACKEND_BUCKET = 'attacker-state-example'
        $env:TERRAFORM_BACKEND_KEY = 'environments/production.tfstate'
        $env:TERRAFORM_BACKEND_LOCK_KEY = 'environments/production.tfstate.tflock'
        $env:TERRAFORM_BACKEND_REGION = 'eu-west-1'
        & (Join-Path $repoRoot 'scripts/deploy.ps1') -Environment staging -ReleaseManifest $manifest -ExpectedSourceSha256 $sourceSha -ExpectedManifestSha256 $manifestSha -SourceCommit ('a' * 40) -ExpectedDeployerImageDigest ('sha256:' + ('b' * 64)) -TerraformVariablesFile $tfvars -TerraformBackendBucket 'oficina-state-example' -TerraformBackendKey 'environments/staging.tfstate' -TerraformBackendLockKey 'environments/staging.tfstate.tflock' -TerraformBackendRegion 'us-east-1' -DryRun | Out-Null
    }
    finally {
        foreach ($name in $backendOverrideNames) {
            if ($null -eq $backendOverrideOriginal[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            else { Set-Item -LiteralPath "Env:$name" -Value $backendOverrideOriginal[$name] }
        }
    }
    Assert-Throws { & (Join-Path $repoRoot 'scripts/deploy.ps1') -Environment staging -ReleaseManifest $manifest -ExpectedSourceSha256 $sourceSha -ExpectedManifestSha256 $manifestSha -SourceCommit ('a' * 40) -ExpectedDeployerImageDigest ('sha256:' + ('b' * 64)) -TerraformVariablesFile $tfvars -TerraformBackendBucket 'oficina-state-example' -TerraformBackendKey 'environments/production.tfstate' -TerraformBackendLockKey 'environments/production.tfstate.tflock' -TerraformBackendRegion 'us-east-1' -DryRun } 'a staging executor must reject the production state key before Terraform initialization.'
    Assert-Throws { & (Join-Path $repoRoot 'scripts/deploy.ps1') -Environment staging -ReleaseManifest $manifest -ExpectedSourceSha256 $sourceSha -ExpectedManifestSha256 $manifestSha -SourceCommit ('a' * 40) -ExpectedDeployerImageDigest ('sha256:' + ('b' * 64)) -TerraformVariablesFile $tfvars -TerraformBackendBucket 'oficina-state-example' -TerraformBackendKey 'environments/staging.tfstate' -TerraformBackendLockKey 'environments/production.tfstate.tflock' -TerraformBackendRegion 'us-east-1' -DryRun } 'an executor must reject a lock context outside its reviewed state key.'
    Assert-Throws { & (Join-Path $repoRoot 'scripts/start-deploy.ps1') -Environment staging -SourceZip $bundle -ExpectedSha256 $sourceSha -ReleaseManifest $manifest -ExpectedManifestSha256 $manifestSha -Bucket 'oficina-artifacts-example' -SourcePrefix 'releases/k8s/staging' -ProjectName 'unreviewed-staging-deploy' -DeployerImageDigest ('b' * 64) -SourceCommit ('a' * 40) -CloudWindowEvidenceFile $openEvidence -TerraformVariablesFile $tfvars -DryRun } 'an unreviewed CodeBuild project must be rejected before launch.'
    Assert-Throws { & (Join-Path $repoRoot 'scripts/start-deploy.ps1') -Environment production -SourceZip $bundle -ExpectedSha256 $sourceSha -ReleaseManifest $manifest -ExpectedManifestSha256 $manifestSha -Bucket 'oficina-artifacts-example' -SourcePrefix 'releases/k8s/production' -ProjectName 'oficina-phase3-oficina-k8s-infra-production-deploy' -DeployerImageDigest ('b' * 64) -SourceCommit ('a' * 40) -CloudWindowEvidenceFile $openEvidence -TerraformVariablesFile $tfvars -DryRun } 'production must require a staging promotion manifest.'

    $promotion = Join-Path $temp 'staging-promotion.json'
    @{ schemaVersion = 1; environment = 'staging'; sourceCommit = ('a' * 40); artifactSha256 = $sourceSha; sourceKey = 'releases/k8s/staging/bundle.zip'; sourceVersionId = 'source-version'; releaseManifestKey = ('releases/k8s/staging/manifests/' + ('a' * 40) + '.json'); releaseManifestVersionId = 'manifest-version'; releaseManifestSha256 = $manifestSha; codeBuildProjectName = 'oficina-phase3-oficina-k8s-infra-staging-deploy'; codeBuildBuildId = 'oficina-phase3-oficina-k8s-infra-staging-deploy:abc123'; buildStatus = 'SUCCEEDED'; issuedAtUtc = $now.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $promotion -NoNewline
    $promotionSha = (Get-FileHash -LiteralPath $promotion -Algorithm SHA256).Hash.ToLowerInvariant()
    $promotionOriginal = Get-Content -LiteralPath $promotion -Raw
    $verifiedPromotion = Join-Path $temp 'verified-promotion.json'
    & (Join-Path $repoRoot 'scripts/verify-staging-promotion.ps1') -Bucket 'oficina-artifacts-example' -PromotionKey ('releases/k8s/staging/promotions/' + ('a' * 40) + '.json') -PromotionVersionId 'promotion-version' -ExpectedPromotionSha256 $promotionSha -ExpectedArtifactSha256 $sourceSha -PromotionFileForTest $promotion -StagingManifestFileForTest $manifest -OutputFile $verifiedPromotion | Out-Null
    $verifiedPromotionDocument = Get-Content -LiteralPath $verifiedPromotion -Raw | ConvertFrom-Json
    Assert-True ($verifiedPromotionDocument.verifiedBy -eq 'verify-staging-promotion.ps1' -and $verifiedPromotionDocument.stagingPromotionKey -eq ('releases/k8s/staging/promotions/' + ('a' * 40) + '.json') -and $verifiedPromotionDocument.stagingPromotionVersionId -eq 'promotion-version') 'a successful staging attestation must produce an immutable local receipt identity.'
    Add-Content -LiteralPath $promotion -Value 'tampered'
    Assert-Throws { & (Join-Path $repoRoot 'scripts/verify-staging-promotion.ps1') -Bucket 'oficina-artifacts-example' -PromotionKey ('releases/k8s/staging/promotions/' + ('a' * 40) + '.json') -PromotionVersionId 'promotion-version' -ExpectedPromotionSha256 $promotionSha -ExpectedArtifactSha256 $sourceSha -PromotionFileForTest $promotion -StagingManifestFileForTest $manifest -OutputFile $verifiedPromotion } 'tampered promotion evidence must be rejected.'
    $unproven = $promotionOriginal | ConvertFrom-Json; $unproven.buildStatus = 'FAILED'; $unproven | ConvertTo-Json | Set-Content -LiteralPath $promotion -NoNewline
    $unprovenSha = (Get-FileHash -LiteralPath $promotion -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Throws { & (Join-Path $repoRoot 'scripts/verify-staging-promotion.ps1') -Bucket 'oficina-artifacts-example' -PromotionKey ('releases/k8s/staging/promotions/' + ('a' * 40) + '.json') -PromotionVersionId 'promotion-version' -ExpectedPromotionSha256 $unprovenSha -ExpectedArtifactSha256 $sourceSha -PromotionFileForTest $promotion -StagingManifestFileForTest $manifest -OutputFile $verifiedPromotion } 'an unsuccessful staging build cannot promote production.'
    Assert-Throws { & (Join-Path $repoRoot 'scripts/verify-staging-promotion.ps1') -Bucket 'oficina-artifacts-example' -PromotionKey ('releases/k8s/staging/promotions/' + ('a' * 40) + '.json') -PromotionVersionId 'promotion-version' -ExpectedPromotionSha256 $unprovenSha -ExpectedArtifactSha256 $sourceSha -PromotionFileForTest (Join-Path $temp 'absent.json') -StagingManifestFileForTest $manifest -OutputFile $verifiedPromotion } 'absent promotion evidence must be rejected.'
    $productionManifest = Join-Path $temp 'production-release-manifest.json'
    @{ schemaVersion = 1; environment = 'production'; sourceCommit = ('a' * 40); artifactSha256 = $sourceSha; deployerImageDigest = ('sha256:' + ('b' * 64)); contractVersion = 'phase3-v2'; migrationVersion = 'platform-v1'; promotedFromStaging = $true; stagingManifestSha256 = $manifestSha; stagingArtifactSha256 = $sourceSha; stagingPromotionSha256 = $promotionSha; stagingPromotionKey = ('releases/k8s/staging/promotions/' + ('a' * 40) + '.json'); stagingPromotionVersionId = 'promotion-version' } | ConvertTo-Json | Set-Content -LiteralPath $productionManifest -NoNewline
    $productionManifestSha = (Get-FileHash -LiteralPath $productionManifest -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Throws { & (Join-Path $repoRoot 'scripts/start-deploy.ps1') -Environment production -SourceZip $bundle -ExpectedSha256 $sourceSha -ReleaseManifest $productionManifest -ExpectedManifestSha256 $productionManifestSha -Bucket 'oficina-artifacts-example' -SourcePrefix 'releases/k8s/production' -ProjectName 'oficina-phase3-oficina-k8s-infra-production-deploy' -DeployerImageDigest ('b' * 64) -SourceCommit ('a' * 40) -CloudWindowEvidenceFile $openEvidence -TerraformVariablesFile $tfvars -DryRun } 'production must not launch without a verified staging promotion document.'
    & (Join-Path $repoRoot 'scripts/start-deploy.ps1') -Environment production -SourceZip $bundle -ExpectedSha256 $sourceSha -ReleaseManifest $productionManifest -ExpectedManifestSha256 $productionManifestSha -Bucket 'oficina-artifacts-example' -SourcePrefix 'releases/k8s/production' -ProjectName 'oficina-phase3-oficina-k8s-infra-production-deploy' -DeployerImageDigest ('b' * 64) -SourceCommit ('a' * 40) -CloudWindowEvidenceFile $openEvidence -TerraformVariablesFile $tfvars -VerifiedPromotionFile $verifiedPromotion -DryRun | Out-Null
    $substituteReceipt = Join-Path $temp 'substitute-receipt.json'
    $substituteReceiptDocument = Get-Content -LiteralPath $verifiedPromotion -Raw | ConvertFrom-Json
    $substituteReceiptDocument.stagingPromotionVersionId = 'different-immutable-version'
    $substituteReceiptDocument | ConvertTo-Json | Set-Content -LiteralPath $substituteReceipt -NoNewline
    Assert-Throws { & (Join-Path $repoRoot 'scripts/start-deploy.ps1') -Environment production -SourceZip $bundle -ExpectedSha256 $sourceSha -ReleaseManifest $productionManifest -ExpectedManifestSha256 $productionManifestSha -Bucket 'oficina-artifacts-example' -SourcePrefix 'releases/k8s/production' -ProjectName 'oficina-phase3-oficina-k8s-infra-production-deploy' -DeployerImageDigest ('b' * 64) -SourceCommit ('a' * 40) -CloudWindowEvidenceFile $openEvidence -TerraformVariablesFile $tfvars -VerifiedPromotionFile $substituteReceipt -DryRun } 'a substitute receipt version must not authorize production.'
    $mismatchedReceipt = Join-Path $temp 'mismatched-receipt.json'
    $mismatchedReceiptDocument = Get-Content -LiteralPath $verifiedPromotion -Raw | ConvertFrom-Json
    $mismatchedReceiptDocument.promotionSha256 = ('c' * 64)
    $mismatchedReceiptDocument | ConvertTo-Json | Set-Content -LiteralPath $mismatchedReceipt -NoNewline
    Assert-Throws { & (Join-Path $repoRoot 'scripts/start-deploy.ps1') -Environment production -SourceZip $bundle -ExpectedSha256 $sourceSha -ReleaseManifest $productionManifest -ExpectedManifestSha256 $productionManifestSha -Bucket 'oficina-artifacts-example' -SourcePrefix 'releases/k8s/production' -ProjectName 'oficina-phase3-oficina-k8s-infra-production-deploy' -DeployerImageDigest ('b' * 64) -SourceCommit ('a' * 40) -CloudWindowEvidenceFile $openEvidence -TerraformVariablesFile $tfvars -VerifiedPromotionFile $mismatchedReceipt -DryRun } 'a receipt with a mismatched promotion digest must not authorize production.'

    $workflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/ci-cd.yml') -Raw
    Assert-Contains $workflow 'pull_request:' 'PR validation must be present.'
    Assert-Contains $workflow "github.ref == 'refs/heads/develop'" 'develop must be the only staging release source.'
    Assert-Contains $workflow "github.ref == 'refs/heads/main'" 'main must be the only production release source.'
    Assert-Contains $workflow 'environment: staging' 'staging must use the protected GitHub environment.'
    Assert-Contains $workflow 'environment: production' 'production must use the protected GitHub environment.'
    Assert-Contains $workflow 'verify-staging-promotion.ps1' 'production must verify a named staging release before launch.'
    Assert-Contains $workflow 'release-readiness-contract.ps1' 'pull requests must execute the release-readiness contract.'
    Assert-Contains $workflow 'FOUNDATION_OUTPUT_RECEIPT_JSON' 'platform deployments must receive a protected foundation-output receipt.'
    Assert-Contains $workflow 'resolve-foundation-outputs.ps1' 'platform deployments must resolve verified foundation outputs before tfvars upload.'
    Assert-Contains $workflow 'stagingPromotionVersionId = $promotion.stagingPromotionVersionId' 'production manifests must bind the immutable staging promotion version.'
    Assert-Contains $workflow 'cancel-in-progress: false' 'deployments must not cancel a running state mutation.'
    Assert-Contains $workflow 'id-token: write' 'release jobs must use short-lived OIDC.'
    Assert-True (-not $workflow.Contains('AWS_ACCESS_KEY_ID')) 'CI must not use fixed AWS credentials.'
    Assert-True (-not $workflow.Contains('echo $CLOUD_WINDOW_EVIDENCE_JSON')) 'CI must not print cloud-window evidence.'

    $executor = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/modules/deployment-executor/main.tf') -Raw
    Assert-Contains $executor 'inline_deployment_buildspec_template' 'CodeBuild must use the Terraform-owned bootstrap template.'
    Assert-Contains $executor '--version-id' 'trusted bootstrap must download immutable S3 object versions.'
    Assert-Contains $executor 'Source digest mismatch.' 'trusted bootstrap must verify the source bundle digest.'
    Assert-Contains $executor 'Release manifest digest mismatch.' 'trusted bootstrap must verify the release manifest digest.'
    Assert-Contains $executor 'reviewed_tfvars_path' 'each executor must render its trusted tfvars path into the bootstrap.'
    Assert-Contains $executor 'reviewed_deployment_mode' 'each executor must render its trusted deployment mode into the bootstrap.'
    Assert-True (-not $executor.Contains('name  = "DEPLOYMENT_TFVARS_PATH"')) 'CodeBuild must not declare an overrideable tfvars-path environment variable.'
    Assert-True (-not $executor.Contains('name  = "DEPLOYMENT_MODE"')) 'CodeBuild must not declare an overrideable deployment-mode environment variable.'
    Assert-Contains $executor 'TERRAFORM_BACKEND_BUCKET' 'each executor must receive its trusted Terraform backend bucket.'
    Assert-Contains $executor 'TERRAFORM_BACKEND_KEY' 'each executor must receive its exact trusted Terraform backend key.'
    Assert-Contains $executor 'TERRAFORM_BACKEND_LOCK_KEY' 'each executor must receive the lock context derived from its backend key.'
    Assert-Contains $executor 'reviewed_backend_key' 'the Terraform-owned bootstrap must use a literal reviewed backend key.'
    Assert-Contains $executor 'StartBuild environmentVariablesOverride cannot alter these values.' 'the backend must be outside StartBuild environment overrides.'
    Assert-True (-not $executor.Contains('$${TERRAFORM_BACKEND_KEY}')) 'the bootstrap must never read an overrideable Terraform backend key.'
    Assert-True (-not $executor.Contains('name  = "TERRAFORM_BACKEND_KEY"')) 'CodeBuild must not declare an overrideable backend-key environment variable.'
    Assert-Contains $executor 'ReadWriteOnlyItsTerraformState' 'Terraform backend access must be scoped to the executor state object.'
    Assert-Contains $executor 'LockOnlyItsTerraformLockfile' 'Terraform backend lock access must be scoped to the executor lockfile.'
    Assert-Contains $executor 'RunOnlyReviewedKubernetesPlatformProviderActions' 'the Kubernetes executor must receive the reviewed provider action set.'
    Assert-Contains $executor 's3:DeleteObject' 'only the native lockfile policy may release Terraform state locks.'
    $bootstrap = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/modules/bootstrap/main.tf') -Raw
    Assert-Contains $bootstrap 'ReadOnlySameRepositoryStagingPromotionEvidence' 'production launchers must read only their own staging promotion evidence.'
    Assert-Contains $bootstrap 'Every production launcher requires a same-repository staging launcher' 'a production promotion path must not exist without its staging peer.'
    Assert-Contains $bootstrap 'DenyBuildspecOverride' 'the launcher must deny replacing the Terraform-owned bootstrap at StartBuild.'
    Assert-Contains $bootstrap 'codebuild:source.buildspec' 'the launcher must use the CodeBuild buildspec override condition key.'
    Assert-Contains $bootstrap 'DenyDeploymentControlOverrides' 'the launcher must deny deployment-control environment overrides.'
    Assert-Contains $bootstrap 'codebuild:environment.environmentVariables.name' 'the launcher must constrain CodeBuild environment override names.'
    Assert-Contains $bootstrap 'ReadOnlyVersionedFoundationOutputArtifact' 'Kubernetes launchers must read only the versioned foundation-output prefix.'
    Assert-Contains $bootstrap 'PublishOnlyVersionedFoundationOutputs' 'foundation publication must be restricted to its immutable artifact prefix.'
    $deploy = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/deploy.ps1') -Raw
    Assert-Contains $deploy '-out=$plan' 'Terraform must produce a reviewed plan before apply.'
    Assert-Contains $deploy 'apply -input=false $plan' 'Terraform may apply only its reviewed plan file.'
    Assert-Contains $deploy '-backend-config=bucket=$TerraformBackendBucket' 'Terraform init must use the executor-declared backend bucket.'
    Assert-Contains $deploy '-backend-config=key=$TerraformBackendKey' 'Terraform init must use the executor-declared exact state key.'
    Assert-Contains $deploy '-backend-config=use_lockfile=true' 'Terraform init must use the S3 lockfile derived from the reviewed state key.'
    Assert-True (-not $deploy.Contains('terraform destroy')) 'deployment script must not contain a destroy path.'
    Assert-Contains (Get-Content -LiteralPath (Join-Path $repoRoot 'infra/environments/staging/backend.tf') -Raw) 'backend "s3" { use_lockfile = true }' 'the staging root must declare an S3 backend with native lockfile support.'
    Assert-Contains (Get-Content -LiteralPath (Join-Path $repoRoot 'infra/environments/production/backend.tf') -Raw) 'backend "s3" { use_lockfile = true }' 'the production root must declare an S3 backend with native lockfile support.'

    Write-Output 'PASS: pipeline contracts enforce environment gates, immutable artifact checks, cloud window, output filtering, and non-stealable deployment locks.'
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
