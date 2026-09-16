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
    @{ vpc_id = @{ value = 'vpc-123' }; private_subnet_ids = @{ value = @('subnet-a', 'subnet-b') }; database_subnet_ids = @{ value = @('subnet-db') }; cluster_name = @{ value = 'oficina-phase3' }; cluster_oidc_provider_arn = @{ value = 'arn:aws:iam::123456789012:oidc-provider/example' }; codebuild_projects = @{ value = @{ k8s_staging = @{ roleArn = 'arn:aws:iam::123456789012:role/k8s' } } }; master_secret_arn = @{ value = 'must-not-export' } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outputs -NoNewline
    $published = Join-Path $temp 'outputs.v1.json'
    & (Join-Path $repoRoot 'scripts/export-outputs.ps1') -TerraformOutputFile $outputs -Scope foundation -Environment foundation -SourceCommit ('a' * 40) -OutputFile $published | Out-Null
    $document = Get-Content -LiteralPath $published -Raw | ConvertFrom-Json
    Assert-True ($document.schemaVersion -eq 1 -and $document.outputs.vpcId -eq 'vpc-123') 'only mapped outputs must be exported in schema v1.'
    Assert-True ($null -eq $document.outputs.PSObject.Properties['masterSecretArn']) 'secret/state-like output names must not appear in an exported document.'
    $badAllowlist = Join-Path $temp 'bad-allowlist.json'
    @{ schemaVersion = 1; repository = 'oficina-k8s-infra'; scopes = @{ foundation = @{ masterSecretArn = 'master_secret_arn' } } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $badAllowlist -NoNewline
    Assert-Throws { & (Join-Path $repoRoot 'scripts/export-outputs.ps1') -TerraformOutputFile $outputs -Scope foundation -Environment foundation -SourceCommit ('a' * 40) -AllowlistFile $badAllowlist -OutputFile $published } 'allowlists containing secret/state fields must be rejected.'

    $bundle = Join-Path $temp 'bundle.zip'; [System.IO.File]::WriteAllBytes($bundle, [byte[]](1, 2, 3, 4))
    $sourceSha = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = Join-Path $temp 'release-manifest.json'
    @{ schemaVersion = 1; environment = 'staging'; sourceCommit = ('a' * 40); artifactSha256 = $sourceSha; deployerImageDigest = ('sha256:' + ('b' * 64)); contractVersion = 'phase3-v2'; migrationVersion = 'platform-v1'; promotedFromStaging = $false } | ConvertTo-Json | Set-Content -LiteralPath $manifest -NoNewline
    $manifestSha = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
    $openEvidence = Join-Path $temp 'open-window.json'
    [ordered]@{ windowStartUtc = $now.AddMinutes(-2).ToString('o'); windowEndUtc = $now.AddMinutes(30).ToString('o'); recordedAtUtc = $now.ToString('o'); accountEvidenceReference = 'reviewed-study-account-evidence'; projectAllowanceUsd = 80; reserveUsd = 20; currentEstimatedSpendUsd = 0 } | ConvertTo-Json | Set-Content -LiteralPath $openEvidence -NoNewline
    & (Join-Path $repoRoot 'scripts/start-deploy.ps1') -Environment staging -SourceZip $bundle -ExpectedSha256 $sourceSha -ReleaseManifest $manifest -ExpectedManifestSha256 $manifestSha -Bucket 'oficina-artifacts-example' -SourcePrefix 'releases/k8s/staging' -ProjectName 'oficina-phase3-oficina-k8s-infra-staging-deploy' -DeployerImageDigest ('b' * 64) -SourceCommit ('a' * 40) -CloudWindowEvidenceFile $openEvidence -DryRun | Out-Null
    Assert-Throws { & (Join-Path $repoRoot 'scripts/start-deploy.ps1') -Environment staging -SourceZip $bundle -ExpectedSha256 $sourceSha -ReleaseManifest $manifest -ExpectedManifestSha256 $manifestSha -Bucket 'oficina-artifacts-example' -SourcePrefix 'releases/k8s/staging' -ProjectName 'unreviewed-staging-deploy' -DeployerImageDigest ('b' * 64) -SourceCommit ('a' * 40) -CloudWindowEvidenceFile $openEvidence -DryRun } 'an unreviewed CodeBuild project must be rejected before launch.'
    Assert-Throws { & (Join-Path $repoRoot 'scripts/start-deploy.ps1') -Environment production -SourceZip $bundle -ExpectedSha256 $sourceSha -ReleaseManifest $manifest -ExpectedManifestSha256 $manifestSha -Bucket 'oficina-artifacts-example' -SourcePrefix 'releases/k8s/production' -ProjectName 'oficina-phase3-oficina-k8s-infra-production-deploy' -DeployerImageDigest ('b' * 64) -SourceCommit ('a' * 40) -CloudWindowEvidenceFile $openEvidence -DryRun } 'production must require a staging promotion manifest.'

    $workflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/ci-cd.yml') -Raw
    Assert-Contains $workflow 'pull_request:' 'PR validation must be present.'
    Assert-Contains $workflow "github.ref == 'refs/heads/develop'" 'develop must be the only staging release source.'
    Assert-Contains $workflow "github.ref == 'refs/heads/main'" 'main must be the only production release source.'
    Assert-Contains $workflow 'environment: staging' 'staging must use the protected GitHub environment.'
    Assert-Contains $workflow 'environment: production' 'production must use the protected GitHub environment.'
    Assert-Contains $workflow 'Production content differs from the staging-tested artifact' 'production must reject content that did not pass through staging.'
    Assert-Contains $workflow 'cancel-in-progress: false' 'deployments must not cancel a running state mutation.'
    Assert-Contains $workflow 'id-token: write' 'release jobs must use short-lived OIDC.'
    Assert-True (-not $workflow.Contains('AWS_ACCESS_KEY_ID')) 'CI must not use fixed AWS credentials.'
    Assert-True (-not $workflow.Contains('echo $CLOUD_WINDOW_EVIDENCE_JSON')) 'CI must not print cloud-window evidence.'

    $executor = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/modules/deployment-executor/main.tf') -Raw
    Assert-Contains $executor 'buildspec = local.inline_deployment_buildspec' 'CodeBuild must use the Terraform-owned bootstrap buildspec.'
    Assert-Contains $executor '--version-id' 'trusted bootstrap must download immutable S3 object versions.'
    Assert-Contains $executor 'Source digest mismatch.' 'trusted bootstrap must verify the source bundle digest.'
    Assert-Contains $executor 'Release manifest digest mismatch.' 'trusted bootstrap must verify the release manifest digest.'
    $deploy = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/deploy.ps1') -Raw
    Assert-Contains $deploy '-out=$plan' 'Terraform must produce a reviewed plan before apply.'
    Assert-Contains $deploy 'apply -input=false $plan' 'Terraform may apply only its reviewed plan file.'
    Assert-True (-not $deploy.Contains('terraform destroy')) 'deployment script must not contain a destroy path.'

    Write-Output 'PASS: pipeline contracts enforce environment gates, immutable artifact checks, cloud window, output filtering, and non-stealable deployment locks.'
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
