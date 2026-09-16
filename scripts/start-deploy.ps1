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
$expectedProjectName = "oficina-phase3-oficina-k8s-infra-$Environment-deploy"
$expectedSourcePrefix = "releases/k8s/$Environment"
if ($ProjectName -cne $expectedProjectName) { Fail 'project name is not the reviewed executor for the requested environment.' }
if ($SourcePrefix -cne $expectedSourcePrefix) { Fail 'source prefix is not the reviewed prefix for the requested environment.' }

$actualSourceSha = Get-Sha256 $SourceZip
if ($actualSourceSha -cne $ExpectedSha256) { Fail 'source digest mismatch.' }
$actualManifestSha = Get-Sha256 $ReleaseManifest
if ($actualManifestSha -cne $ExpectedManifestSha256) { Fail 'release-manifest digest mismatch.' }
try { $manifest = Get-Content -LiteralPath $ReleaseManifest -Raw | ConvertFrom-Json }
catch { Fail 'release manifest is not valid JSON.' }

if ($manifest.schemaVersion -ne 1 -or [string](Require $manifest 'environment') -cne $Environment) { Fail 'release manifest environment is invalid.' }
if ([string](Require $manifest 'sourceCommit') -cne $SourceCommit) { Fail 'release manifest source commit is invalid.' }
if ([string](Require $manifest 'artifactSha256') -cne $ExpectedSha256) { Fail 'release manifest does not bind the exact source digest.' }
if ([string](Require $manifest 'deployerImageDigest') -cne "sha256:$DeployerImageDigest") { Fail 'release manifest does not bind the reviewed deployer image digest.' }
$null = Require $manifest 'contractVersion'
$null = Require $manifest 'migrationVersion'
if ($Environment -eq 'production' -and ($manifest.promotedFromStaging -ne $true -or [string](Require $manifest 'stagingManifestSha256') -notmatch '^[a-f0-9]{64}$' -or [string](Require $manifest 'stagingArtifactSha256') -cne $ExpectedSha256)) {
    Fail 'production must consume the exact staging-tested artifact and promotion manifest.'
}

& (Join-Path $PSScriptRoot 'check-cloud-window.ps1') -EvidenceFile $CloudWindowEvidenceFile | Out-Null
if ($DryRun) {
    Write-Output 'Deployment launch request validated; dry run did not call AWS.'
    exit 0
}

$sourceKey = "$SourcePrefix/bundle.zip"
$manifestKey = "$SourcePrefix/manifests/$SourceCommit.json"
$sourceResult = & aws s3api put-object --bucket $Bucket --key $sourceKey --body $SourceZip --output json 2>$null
if ($LASTEXITCODE -ne 0) { Fail 'versioned source upload failed.' }
$sourceUpload = $sourceResult | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($sourceUpload.VersionId)) { Fail 'source upload returned no S3 VersionId.' }

$manifestResult = & aws s3api put-object --bucket $Bucket --key $manifestKey --body $ReleaseManifest --output json 2>$null
if ($LASTEXITCODE -ne 0) { Fail 'versioned release-manifest upload failed.' }
$manifestUpload = $manifestResult | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($manifestUpload.VersionId)) { Fail 'release-manifest upload returned no S3 VersionId.' }

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
    "name=DEPLOYER_IMAGE_DIGEST,value=sha256:$DeployerImageDigest,type=PLAINTEXT"
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
    if ($status -in @('SUCCEEDED')) { Write-Output 'Deployment build completed successfully.'; exit 0 }
    if ($status -in @('FAILED', 'FAULT', 'STOPPED', 'TIMED_OUT')) { Fail "CodeBuild finished with status '$status'." }
} while ([datetime]::UtcNow -lt $deadline)

Fail 'CodeBuild did not reach a terminal status before its approved timeout.'
