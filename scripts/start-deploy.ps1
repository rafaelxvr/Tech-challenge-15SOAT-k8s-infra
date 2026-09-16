[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('staging', 'production')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceZip,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-f0-9]{64}$')]
    [string]$ExpectedSha256,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ReleaseManifest,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-f0-9]{64}$')]
    [string]$ExpectedManifestSha256,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$')]
    [string]$Bucket,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9/_-]*$')]
    [string]$SourcePrefix,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$ProjectName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-f0-9]{64}$')]
    [string]$DeployerImageDigest,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-f0-9]{40}$')]
    [string]$SourceCommit,

    [Parameter(Mandatory)]
    [string]$CloudWindowEvidenceFile,

    [Parameter(Mandatory)]
    [string]$TerraformVariablesFile,

    [string]$PromotionEvidenceOutputFile,

    [string]$VerifiedPromotionFile,

    [ValidateRange(60, 2400)]
    [int]$TimeoutSeconds = 2100,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Fail([string]$Message) { throw "Deployment launch failed: $Message" }
function Require([object]$Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or ([string]$property.Value).Trim().Length -eq 0) { Fail "release manifest is missing '$Name'." }
    return $property.Value
}
function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

if (-not (Test-Path -LiteralPath $SourceZip -PathType Leaf)) { Fail 'source zip does not exist.' }
if (-not (Test-Path -LiteralPath $ReleaseManifest -PathType Leaf)) { Fail 'release manifest does not exist.' }
if (-not (Test-Path -LiteralPath $TerraformVariablesFile -PathType Leaf)) { Fail 'Terraform variables file does not exist.' }
$expectedProjectName = "oficina-phase3-oficina-k8s-infra-$Environment-deploy"
$expectedSourcePrefix = "releases/k8s/$Environment"
if ($ProjectName -cne $expectedProjectName) { Fail 'project name is not the reviewed executor for the requested environment.' }
if ($SourcePrefix -cne $expectedSourcePrefix) { Fail 'source prefix is not the reviewed prefix for the requested environment.' }

$actualSourceSha = Get-Sha256 $SourceZip
if ($actualSourceSha -cne $ExpectedSha256) { Fail 'source digest mismatch.' }
$actualManifestSha = Get-Sha256 $ReleaseManifest
if ($actualManifestSha -cne $ExpectedManifestSha256) { Fail 'release-manifest digest mismatch.' }
$tfvarsSha = Get-Sha256 $TerraformVariablesFile
try { $manifest = Get-Content -LiteralPath $ReleaseManifest -Raw | ConvertFrom-Json }
catch { Fail 'release manifest is not valid JSON.' }

if ($manifest.schemaVersion -ne 1 -or [string](Require $manifest 'environment') -cne $Environment) { Fail 'release manifest environment is invalid.' }
if ([string](Require $manifest 'sourceCommit') -cne $SourceCommit) { Fail 'release manifest source commit is invalid.' }
if ([string](Require $manifest 'artifactSha256') -cne $ExpectedSha256) { Fail 'release manifest does not bind the exact source digest.' }
if ([string](Require $manifest 'deployerImageDigest') -cne "sha256:$DeployerImageDigest") { Fail 'release manifest does not bind the reviewed deployer image digest.' }
$null = Require $manifest 'contractVersion'
$null = Require $manifest 'migrationVersion'
if ($Environment -eq 'production' -and ($manifest.promotedFromStaging -ne $true -or [string](Require $manifest 'stagingManifestSha256') -notmatch '^[a-f0-9]{64}$' -or [string](Require $manifest 'stagingArtifactSha256') -cne $ExpectedSha256 -or [string](Require $manifest 'stagingPromotionSha256') -notmatch '^[a-f0-9]{64}$' -or [string](Require $manifest 'stagingPromotionKey') -notmatch '^releases/k8s/staging/promotions/[a-f0-9]{40}\.json$' -or [string]::IsNullOrWhiteSpace([string](Require $manifest 'stagingPromotionVersionId')))) {
    Fail 'production must consume the exact staging-tested artifact and immutable promotion receipt.'
}
if ($Environment -eq 'production') {
    if (-not (Test-Path -LiteralPath $VerifiedPromotionFile -PathType Leaf)) { Fail 'production requires a locally verified staging promotion document.' }
    try { $verifiedPromotion = Get-Content -LiteralPath $VerifiedPromotionFile -Raw | ConvertFrom-Json }
    catch { Fail 'verified staging promotion document is not valid JSON.' }
    if ($verifiedPromotion.schemaVersion -ne 1 -or [string]$verifiedPromotion.verifiedBy -cne 'verify-staging-promotion.ps1' -or [string]$verifiedPromotion.stagingArtifactSha256 -cne $ExpectedSha256 -or [string]$verifiedPromotion.stagingManifestSha256 -cne [string]$manifest.stagingManifestSha256 -or [string]$verifiedPromotion.promotionSha256 -cne [string]$manifest.stagingPromotionSha256 -or [string]$verifiedPromotion.stagingPromotionKey -cne [string]$manifest.stagingPromotionKey -or [string]$verifiedPromotion.stagingPromotionVersionId -cne [string]$manifest.stagingPromotionVersionId) {
        Fail 'production promotion document does not prove the exact staging artifact, manifest, and immutable receipt identity.'
    }
}

& (Join-Path $PSScriptRoot 'check-cloud-window.ps1') -EvidenceFile $CloudWindowEvidenceFile | Out-Null
if ($DryRun) {
    Write-Output 'Deployment launch request validated; dry run did not call AWS.'
    exit 0
}

$sourceKey = "$SourcePrefix/bundle.zip"
$manifestKey = "$SourcePrefix/manifests/$SourceCommit.json"
$tfvarsKey = "$SourcePrefix/config/$SourceCommit.tfvars.json"
$sourceResult = & aws s3api put-object --bucket $Bucket --key $sourceKey --body $SourceZip --output json 2>$null
if ($LASTEXITCODE -ne 0) { Fail 'versioned source upload failed.' }
$sourceUpload = $sourceResult | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($sourceUpload.VersionId)) { Fail 'source upload returned no S3 VersionId.' }

$manifestResult = & aws s3api put-object --bucket $Bucket --key $manifestKey --body $ReleaseManifest --output json 2>$null
if ($LASTEXITCODE -ne 0) { Fail 'versioned release-manifest upload failed.' }
$manifestUpload = $manifestResult | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($manifestUpload.VersionId)) { Fail 'release-manifest upload returned no S3 VersionId.' }

$tfvarsResult = & aws s3api put-object --bucket $Bucket --key $tfvarsKey --body $TerraformVariablesFile --output json 2>$null
if ($LASTEXITCODE -ne 0) { Fail 'versioned Terraform variables upload failed.' }
$tfvarsUpload = $tfvarsResult | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($tfvarsUpload.VersionId)) { Fail 'Terraform variables upload returned no S3 VersionId.' }

$overrides = @(
    "name=DEPLOY_ENVIRONMENT,value=$Environment,type=PLAINTEXT",
    "name=SOURCE_BUCKET,value=$Bucket,type=PLAINTEXT",
    "name=SOURCE_KEY,value=$sourceKey,type=PLAINTEXT",
    "name=SOURCE_VERSION_ID,value=$($sourceUpload.VersionId),type=PLAINTEXT",
    "name=EXPECTED_SHA256,value=$ExpectedSha256,type=PLAINTEXT",
    "name=RELEASE_MANIFEST_KEY,value=$manifestKey,type=PLAINTEXT",
    "name=RELEASE_MANIFEST_VERSION_ID,value=$($manifestUpload.VersionId),type=PLAINTEXT",
    "name=EXPECTED_MANIFEST_SHA256,value=$ExpectedManifestSha256,type=PLAINTEXT",
    "name=SOURCE_COMMIT,value=$SourceCommit,type=PLAINTEXT",
    "name=DEPLOYER_IMAGE_DIGEST,value=sha256:$DeployerImageDigest,type=PLAINTEXT",
    "name=TFVARS_OBJECT_KEY,value=$tfvarsKey,type=PLAINTEXT",
    "name=TFVARS_VERSION_ID,value=$($tfvarsUpload.VersionId),type=PLAINTEXT",
    "name=EXPECTED_TFVARS_SHA256,value=$tfvarsSha,type=PLAINTEXT"
)
$started = & aws codebuild start-build --project-name $ProjectName --source-version $sourceUpload.VersionId --environment-variables-override $overrides --output json 2>$null
if ($LASTEXITCODE -ne 0) { Fail 'CodeBuild launch failed.' }
$build = $started | ConvertFrom-Json
$buildId = [string]$build.build.id
if ([string]::IsNullOrWhiteSpace($buildId)) { Fail 'CodeBuild launch returned no build ID.' }

$deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Seconds 10
    $current = & aws codebuild batch-get-builds --ids $buildId --output json 2>$null
    if ($LASTEXITCODE -ne 0) { Fail 'unable to retrieve CodeBuild status.' }
    $status = [string](($current | ConvertFrom-Json).builds[0].buildStatus)
    if ($status -in @('SUCCEEDED')) {
        if ($Environment -eq 'staging') {
            $promotionKey = "$SourcePrefix/promotions/$SourceCommit.json"
            $promotionPath = Join-Path ([System.IO.Path]::GetTempPath()) "oficina-promotion-$SourceCommit.json"
            try {
                [ordered]@{
                    schemaVersion = 1; environment = 'staging'; sourceCommit = $SourceCommit; artifactSha256 = $ExpectedSha256
                    sourceKey = $sourceKey; sourceVersionId = $sourceUpload.VersionId; releaseManifestKey = $manifestKey; releaseManifestVersionId = $manifestUpload.VersionId; releaseManifestSha256 = $ExpectedManifestSha256
                    codeBuildProjectName = $ProjectName; codeBuildBuildId = $buildId; buildStatus = 'SUCCEEDED'; issuedAtUtc = [datetime]::UtcNow.ToString('o')
                } | ConvertTo-Json | Set-Content -LiteralPath $promotionPath -NoNewline
                $promotionSha = Get-Sha256 $promotionPath
                $promotionResult = & aws s3api put-object --bucket $Bucket --key $promotionKey --body $promotionPath --output json 2>$null
                if ($LASTEXITCODE -ne 0) { Fail 'successful staging build could not publish promotion evidence.' }
                $promotionUpload = $promotionResult | ConvertFrom-Json
                if ([string]::IsNullOrWhiteSpace($promotionUpload.VersionId)) { Fail 'promotion evidence upload returned no S3 VersionId.' }
                if (-not [string]::IsNullOrWhiteSpace($PromotionEvidenceOutputFile)) {
                    [ordered]@{ bucket = $Bucket; key = $promotionKey; versionId = $promotionUpload.VersionId; sha256 = $promotionSha; artifactSha256 = $ExpectedSha256 } | ConvertTo-Json | Set-Content -LiteralPath $PromotionEvidenceOutputFile -NoNewline
                }
            }
            finally { Remove-Item -LiteralPath $promotionPath -Force -ErrorAction SilentlyContinue }
        }
        Write-Output 'Deployment build completed successfully.'; exit 0
    }
    if ($status -in @('FAILED', 'FAULT', 'STOPPED', 'TIMED_OUT')) { Fail "CodeBuild finished with status '$status'." }
} while ([datetime]::UtcNow -lt $deadline)

Fail 'CodeBuild did not reach a terminal status before its approved timeout.'
