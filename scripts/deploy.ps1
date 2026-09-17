[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('staging', 'production')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$ReleaseManifest,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-f0-9]{64}$')]
    [string]$ExpectedSourceSha256,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-f0-9]{64}$')]
    [string]$ExpectedManifestSha256,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-f0-9]{40}$')]
    [string]$SourceCommit,

    [Parameter(Mandatory)]
    [ValidatePattern('^sha256:[a-f0-9]{64}$')]
    [string]$ExpectedDeployerImageDigest,

    [Parameter(Mandatory)]
    [string]$TerraformVariablesFile,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$')]
    [string]$TerraformBackendBucket,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9/_-]*\.tfstate$')]
    [string]$TerraformBackendKey,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9/_-]*\.tfstate\.tflock$')]
    [string]$TerraformBackendLockKey,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z]{2}-[a-z]+-\d+$')]
    [string]$TerraformBackendRegion,

    [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$')]
    [string]$StateBucket,

    [switch]$SharedFoundationMutation,
    [switch]$ApplyReviewedPlan,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Fail([string]$Message) { throw "Deployment execution failed: $Message" }
function Require([object]$Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or ([string]$property.Value).Trim().Length -eq 0) { Fail "release manifest is missing '$Name'." }
    return $property.Value
}
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

if (-not (Test-Path -LiteralPath $ReleaseManifest -PathType Leaf)) { Fail 'release manifest does not exist.' }
if (-not (Test-Path -LiteralPath $TerraformVariablesFile -PathType Leaf)) { Fail 'Terraform variables file does not exist.' }
if ((Hash $ReleaseManifest) -cne $ExpectedManifestSha256) { Fail 'release-manifest digest mismatch.' }
try { $manifest = Get-Content -LiteralPath $ReleaseManifest -Raw | ConvertFrom-Json }
catch { Fail 'release manifest is not valid JSON.' }
if ($manifest.schemaVersion -ne 1 -or [string](Require $manifest 'environment') -cne $Environment) { Fail 'release manifest environment is invalid.' }
if ([string](Require $manifest 'sourceCommit') -cne $SourceCommit) { Fail 'release manifest source commit is invalid.' }
if ([string](Require $manifest 'artifactSha256') -cne $ExpectedSourceSha256) { Fail 'source digest is not bound by the release manifest.' }
if ([string](Require $manifest 'deployerImageDigest') -cne $ExpectedDeployerImageDigest) { Fail 'deployer image digest is not bound by the release manifest.' }
$null = Require $manifest 'contractVersion'
$null = Require $manifest 'migrationVersion'
if ($Environment -eq 'production' -and ($manifest.promotedFromStaging -ne $true -or [string](Require $manifest 'stagingManifestSha256') -notmatch '^[a-f0-9]{64}$' -or [string](Require $manifest 'stagingArtifactSha256') -cne $ExpectedSourceSha256 -or [string](Require $manifest 'stagingPromotionSha256') -notmatch '^[a-f0-9]{64}$' -or [string](Require $manifest 'stagingPromotionKey') -notmatch '^releases/k8s/staging/promotions/[a-f0-9]{40}\.json$' -or [string]::IsNullOrWhiteSpace([string](Require $manifest 'stagingPromotionVersionId')))) { Fail 'production deployment is not backed by the exact staging-tested artifact and immutable promotion receipt.' }
$expectedBackendKey = "environments/$Environment.tfstate"
if ($TerraformBackendKey -cne $expectedBackendKey) { Fail "Terraform backend key is not the reviewed state key for '$Environment'." }
if ($TerraformBackendLockKey -cne "$TerraformBackendKey.tflock") { Fail 'Terraform backend lock key is not derived from the reviewed state key.' }
if ($StateBucket -and $StateBucket -cne $TerraformBackendBucket) { Fail 'shared foundation lock bucket must match the reviewed Terraform backend bucket.' }
if ($SharedFoundationMutation -and [string]::IsNullOrWhiteSpace($StateBucket)) { Fail 'shared foundation mutations require the reviewed state bucket lock.' }
if ($DryRun) { Write-Output 'Deployment execution inputs validated; dry run did not run Terraform.'; exit 0 }

$repoRoot = Split-Path -Parent $PSScriptRoot
$root = Join-Path $repoRoot "infra/environments/$Environment"
if (-not (Test-Path -LiteralPath $root -PathType Container)) { Fail "Terraform root for '$Environment' does not exist." }
$plan = Join-Path ([System.IO.Path]::GetTempPath()) "oficina-$Environment-$SourceCommit.tfplan"
$ownerToken = [guid]::NewGuid().ToString()
$locked = $false
try {
    if ($SharedFoundationMutation) {
        & (Join-Path $PSScriptRoot 'deployment-lock.ps1') -Action Acquire -StateBucket $StateBucket -OwnerToken $ownerToken | Out-Null
        $locked = $true
    }
    & terraform -chdir=$root init -input=false "-backend-config=bucket=$TerraformBackendBucket" "-backend-config=key=$TerraformBackendKey" "-backend-config=region=$TerraformBackendRegion" '-backend-config=use_lockfile=true'
    if ($LASTEXITCODE -ne 0) { Fail 'terraform init failed.' }
    & terraform -chdir=$root validate
    if ($LASTEXITCODE -ne 0) { Fail 'terraform validate failed.' }
    & terraform -chdir=$root plan -input=false -lock-timeout=5m -var-file=$TerraformVariablesFile -out=$plan
    if ($LASTEXITCODE -ne 0) { Fail 'terraform plan failed; apply was not attempted.' }
    if ($ApplyReviewedPlan) {
        & terraform -chdir=$root apply -input=false $plan
        if ($LASTEXITCODE -ne 0) { Fail 'terraform apply of the reviewed plan failed.' }
        Write-Output 'Reviewed Terraform plan applied.'
    }
    else { Write-Output 'Terraform plan completed; apply is intentionally disabled.' }
}
finally {
    Remove-Item -LiteralPath $plan -Force -ErrorAction SilentlyContinue
    if ($locked) { & (Join-Path $PSScriptRoot 'deployment-lock.ps1') -Action Release -StateBucket $StateBucket -OwnerToken $ownerToken | Out-Null }
}
