[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$')]
    [string]$Bucket,

    [Parameter(Mandatory)]
    [ValidatePattern('^releases/k8s/staging/promotions/[a-f0-9]{40}\.json$')]
    [string]$PromotionKey,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PromotionVersionId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-f0-9]{64}$')]
    [string]$ExpectedPromotionSha256,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-f0-9]{64}$')]
    [string]$ExpectedArtifactSha256,

    [Parameter(Mandatory)]
    [string]$OutputFile,

    [string]$PromotionFileForTest,
    [string]$StagingManifestFileForTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Fail([string]$Message) { throw "Staging promotion verification failed: $Message" }
function Require([object]$Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or ([string]$property.Value).Trim().Length -eq 0) { Fail "promotion evidence is missing '$Name'." }
    return $property.Value
}
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

$temporary = [System.Collections.Generic.List[string]]::new()
try {
    if (-not [string]::IsNullOrWhiteSpace($PromotionFileForTest)) { $promotionPath = $PromotionFileForTest }
    else {
        $promotionPath = Join-Path ([System.IO.Path]::GetTempPath()) "oficina-promotion-$PromotionVersionId.json"
        $temporary.Add($promotionPath)
        & aws s3api get-object --bucket $Bucket --key $PromotionKey --version-id $PromotionVersionId $promotionPath 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail 'named staging promotion evidence could not be retrieved.' }
    }
    if (-not (Test-Path -LiteralPath $promotionPath -PathType Leaf)) { Fail 'named staging promotion evidence does not exist.' }
    if ((Hash $promotionPath) -cne $ExpectedPromotionSha256) { Fail 'staging promotion evidence digest mismatch.' }
    try { $promotion = Get-Content -LiteralPath $promotionPath -Raw | ConvertFrom-Json }
    catch { Fail 'staging promotion evidence is not valid JSON.' }

    if ($promotion.schemaVersion -ne 1 -or [string](Require $promotion 'environment') -cne 'staging') { Fail 'promotion evidence is not a staging attestation.' }
    if ([string](Require $promotion 'buildStatus') -cne 'SUCCEEDED') { Fail 'promotion evidence does not prove a successful staging build.' }
    if ([string](Require $promotion 'codeBuildProjectName') -cne 'oficina-phase3-oficina-k8s-infra-staging-deploy') { Fail 'promotion evidence names an unreviewed CodeBuild project.' }
    if ([string](Require $promotion 'codeBuildBuildId') -notmatch '^oficina-phase3-oficina-k8s-infra-staging-deploy:[A-Za-z0-9-]+$') { Fail 'promotion evidence has an invalid staging build identity.' }
    if ([string](Require $promotion 'artifactSha256') -cne $ExpectedArtifactSha256) { Fail 'production artifact does not match the staging-tested artifact.' }
    $sourceCommit = [string](Require $promotion 'sourceCommit')
    if ($sourceCommit -notmatch '^[a-f0-9]{40}$') { Fail 'promotion evidence has an invalid source commit.' }
    $manifestKey = [string](Require $promotion 'releaseManifestKey')
    if ($manifestKey -cne "releases/k8s/staging/manifests/$sourceCommit.json") { Fail 'promotion evidence points outside the reviewed staging manifest prefix.' }
    $manifestVersion = [string](Require $promotion 'releaseManifestVersionId')
    $manifestSha = [string](Require $promotion 'releaseManifestSha256')
    if ($manifestSha -notmatch '^[a-f0-9]{64}$') { Fail 'promotion evidence has an invalid staging manifest digest.' }

    if (-not [string]::IsNullOrWhiteSpace($StagingManifestFileForTest)) { $manifestPath = $StagingManifestFileForTest }
    else {
        $manifestPath = Join-Path ([System.IO.Path]::GetTempPath()) "oficina-staging-manifest-$manifestVersion.json"
        $temporary.Add($manifestPath)
        & aws s3api get-object --bucket $Bucket --key $manifestKey --version-id $manifestVersion $manifestPath 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail 'named staging release manifest could not be retrieved.' }
    }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Fail 'named staging release manifest does not exist.' }
    if ((Hash $manifestPath) -cne $manifestSha) { Fail 'named staging release manifest digest mismatch.' }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    catch { Fail 'named staging release manifest is not valid JSON.' }
    if ($manifest.schemaVersion -ne 1 -or [string](Require $manifest 'environment') -cne 'staging' -or [string](Require $manifest 'sourceCommit') -cne $sourceCommit -or [string](Require $manifest 'artifactSha256') -cne $ExpectedArtifactSha256) {
        Fail 'named staging release manifest does not match the proven staging release.'
    }

    $verified = [ordered]@{
        schemaVersion = 1; verifiedBy = 'verify-staging-promotion.ps1'; verifiedAtUtc = [datetime]::UtcNow.ToString('o')
        promotionSha256 = $ExpectedPromotionSha256; stagingArtifactSha256 = $ExpectedArtifactSha256; stagingSourceCommit = $sourceCommit
        stagingManifestKey = $manifestKey; stagingManifestVersionId = $manifestVersion; stagingManifestSha256 = $manifestSha
    }
    $parent = Split-Path -Parent $OutputFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $verified | ConvertTo-Json | Set-Content -LiteralPath $OutputFile -NoNewline
    Write-Output 'Named staging promotion and release manifest were verified.'
}
finally { foreach ($path in $temporary) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } }
