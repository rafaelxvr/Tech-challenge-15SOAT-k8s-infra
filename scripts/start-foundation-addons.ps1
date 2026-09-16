[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceZip,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedSha256,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$')][string]$Bucket,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,
    [Parameter(Mandatory)][string]$CloudWindowEvidenceFile,
    [ValidateRange(60, 2400)][int]$TimeoutSeconds = 2100,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Fail([string]$Message) { throw "Foundation addons launch failed: $Message" }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

if (-not (Test-Path -LiteralPath $SourceZip -PathType Leaf)) { Fail 'source zip does not exist.' }
if ((Hash $SourceZip) -cne $ExpectedSha256) { Fail 'source digest mismatch.' }
& (Join-Path $PSScriptRoot 'check-cloud-window.ps1') -EvidenceFile $CloudWindowEvidenceFile | Out-Null

$project = 'oficina-phase3-foundation-addons'
$sourceKey = 'foundation-addons/bundle.zip'
$manifestKey = "foundation-addons/manifests/$SourceCommit.json"
$manifestPath = Join-Path ([System.IO.Path]::GetTempPath()) "oficina-foundation-addons-$SourceCommit.json"
try {
    [ordered]@{ schemaVersion = 1; sourceCommit = $SourceCommit; artifactSha256 = $ExpectedSha256; root = 'infra/foundation-addons' } | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -NoNewline
    $manifestSha = Hash $manifestPath
    if ($DryRun) { Write-Output 'Foundation addons launch request validated; dry run did not call AWS.'; exit 0 }

    $sourceUpload = (& aws s3api put-object --bucket $Bucket --key $sourceKey --body $SourceZip --output json 2>$null | ConvertFrom-Json)
    if ([string]::IsNullOrWhiteSpace([string]$sourceUpload.VersionId)) { Fail 'versioned source upload returned no VersionId.' }
    $manifestUpload = (& aws s3api put-object --bucket $Bucket --key $manifestKey --body $manifestPath --output json 2>$null | ConvertFrom-Json)
    if ([string]::IsNullOrWhiteSpace([string]$manifestUpload.VersionId)) { Fail 'versioned manifest upload returned no VersionId.' }
    $overrides = @(
      "name=ADDONS_SOURCE_BUCKET,value=$Bucket,type=PLAINTEXT",
      "name=ADDONS_SOURCE_KEY,value=$sourceKey,type=PLAINTEXT",
      "name=ADDONS_SOURCE_VERSION_ID,value=$($sourceUpload.VersionId),type=PLAINTEXT",
      "name=ADDONS_EXPECTED_SHA256,value=$ExpectedSha256,type=PLAINTEXT",
      "name=ADDONS_MANIFEST_KEY,value=$manifestKey,type=PLAINTEXT",
      "name=ADDONS_MANIFEST_VERSION_ID,value=$($manifestUpload.VersionId),type=PLAINTEXT",
      "name=ADDONS_EXPECTED_MANIFEST_SHA256,value=$manifestSha,type=PLAINTEXT",
      "name=ADDONS_SOURCE_COMMIT,value=$SourceCommit,type=PLAINTEXT"
    )
    $started = (& aws codebuild start-build --project-name $project --source-version $sourceUpload.VersionId --environment-variables-override $overrides --output json 2>$null | ConvertFrom-Json)
    $buildId = [string]$started.build.id
    if ([string]::IsNullOrWhiteSpace($buildId)) { Fail 'CodeBuild launch returned no build ID.' }
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
      Start-Sleep -Seconds 10
      $current = (& aws codebuild batch-get-builds --ids $buildId --output json 2>$null | ConvertFrom-Json)
      $status = [string]$current.builds[0].buildStatus
      if ($status -eq 'SUCCEEDED') { Write-Output 'Foundation addons build completed successfully.'; exit 0 }
      if ($status -in @('FAILED', 'FAULT', 'STOPPED', 'TIMED_OUT')) { Fail "CodeBuild finished with status '$status'." }
    } while ([datetime]::UtcNow -lt $deadline)
    Fail 'CodeBuild did not reach a terminal status before its approved timeout.'
}
finally { Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue }
