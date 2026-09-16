[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$')]
    [string]$ArtifactBucket,

    [Parameter(Mandatory)]
    [string]$ReceiptFile,

    [Parameter(Mandatory)]
    [string]$BaseTerraformVariablesFile,

    [Parameter(Mandatory)]
    [string]$OutputTerraformVariablesFile,

    # Test-only retrieval paths model an S3 object selected by its immutable
    # VersionId. Normal releases always retrieve from S3 with --version-id.
    [string]$OfflineDirectory,
    [string]$ArtifactFileForTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) { throw "Foundation output resolution failed: $Message" }
function Require([object]$Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or ([string]$property.Value).Trim().Length -eq 0) { Fail "receipt is missing '$Name'." }
    return $property.Value
}
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function OutputValue([object]$Outputs, [string]$Name) {
    $property = $Outputs.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { Fail "foundation artifact is missing '$Name'." }
    return $property.Value
}

if (-not (Test-Path -LiteralPath $ReceiptFile -PathType Leaf)) { Fail 'receipt file does not exist.' }
if (-not (Test-Path -LiteralPath $BaseTerraformVariablesFile -PathType Leaf)) { Fail 'base Terraform variables file does not exist.' }
try { $receipt = Get-Content -LiteralPath $ReceiptFile -Raw | ConvertFrom-Json }
catch { Fail 'receipt is not valid JSON.' }
try { $base = Get-Content -LiteralPath $BaseTerraformVariablesFile -Raw | ConvertFrom-Json }
catch { Fail 'base Terraform variables are not valid JSON.' }
if ($null -ne $base.PSObject.Properties['foundation_outputs']) { Fail 'base Terraform variables must not inject foundation_outputs.' }

$sourceCommit = [string](Require $receipt 'sourceCommit')
$key = [string](Require $receipt 'artifactKey')
$versionId = [string](Require $receipt 'artifactVersionId')
$expectedSha = [string](Require $receipt 'artifactSha256')
if ($receipt.schemaVersion -ne 1 -or [string](Require $receipt 'kind') -cne 'foundation-output' -or [string](Require $receipt 'environment') -cne 'foundation') { Fail 'receipt has an unsupported schema, kind, or environment.' }
if ([string](Require $receipt 'artifactBucket') -cne $ArtifactBucket) { Fail 'receipt artifact bucket does not match the reviewed artifact bucket.' }
if ($sourceCommit -notmatch '^[a-f0-9]{40}$' -or $key -cne "releases/k8s/foundation/outputs/$sourceCommit.json" -or $versionId.Length -eq 0 -or $expectedSha -notmatch '^[a-f0-9]{64}$') { Fail 'receipt does not identify the exact versioned foundation artifact.' }

$artifactPath = Join-Path ([System.IO.Path]::GetTempPath()) ("oficina-foundation-consume-$([guid]::NewGuid()).json")
try {
    if (-not [string]::IsNullOrWhiteSpace($ArtifactFileForTest)) {
        if (-not (Test-Path -LiteralPath $ArtifactFileForTest -PathType Leaf)) { Fail 'test artifact file does not exist.' }
        Copy-Item -LiteralPath $ArtifactFileForTest -Destination $artifactPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($OfflineDirectory)) {
        $offlineArtifact = Join-Path (Join-Path $OfflineDirectory 'versions') "$versionId.json"
        if (-not (Test-Path -LiteralPath $offlineArtifact -PathType Leaf)) { Fail 'the named offline artifact version does not exist.' }
        Copy-Item -LiteralPath $offlineArtifact -Destination $artifactPath
    }
    else {
        & aws s3api get-object --bucket $ArtifactBucket --key $key --version-id $versionId $artifactPath 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail 'named foundation artifact version could not be retrieved.' }
    }
    if ((Hash $artifactPath) -cne $expectedSha) { Fail 'foundation artifact digest does not match the versioned receipt.' }
    try { $artifact = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json }
    catch { Fail 'foundation artifact is not valid JSON.' }
    if ($artifact.schemaVersion -ne 1 -or [string](OutputValue $artifact 'environment') -cne 'foundation' -or [string](OutputValue $artifact 'sourceCommit') -cne $sourceCommit) { Fail 'foundation artifact schema, environment, or source commit is invalid.' }
    $outputs = OutputValue $artifact 'outputs'
    $listeners = OutputValue $outputs 'backendListenerArns'
    $projects = OutputValue $outputs 'codeBuildProjects'
    $stagingListener = [string](OutputValue $listeners 'staging')
    $productionListener = [string](OutputValue $listeners 'production')
    $stagingRole = [string](OutputValue (OutputValue $projects 'k8s_staging') 'roleArn')
    $productionRole = [string](OutputValue (OutputValue $projects 'k8s_production') 'roleArn')
    foreach ($value in @([string](OutputValue $outputs 'vpcId'), [string](OutputValue $outputs 'clusterName'), [string](OutputValue $outputs 'vpcLinkId'), $stagingListener, $productionListener, $stagingRole, $productionRole)) {
        if ([string]::IsNullOrWhiteSpace($value)) { Fail 'foundation artifact contains an empty platform input.' }
    }

    $resolved = [ordered]@{}
    foreach ($property in $base.PSObject.Properties) { $resolved[$property.Name] = $property.Value }
    $resolved.foundation_outputs = [ordered]@{
        vpc_id                = [string](OutputValue $outputs 'vpcId')
        cluster_name          = [string](OutputValue $outputs 'clusterName')
        vpc_link_id           = [string](OutputValue $outputs 'vpcLinkId')
        backend_listener_arns = [ordered]@{ staging = $stagingListener; production = $productionListener }
        codebuild_projects    = [ordered]@{ k8s_staging = [ordered]@{ roleArn = $stagingRole }; k8s_production = [ordered]@{ roleArn = $productionRole } }
    }
    $destination = Split-Path -Parent $OutputTerraformVariablesFile
    if ($destination -and -not (Test-Path -LiteralPath $destination)) { New-Item -ItemType Directory -Path $destination -Force | Out-Null }
    $resolved | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputTerraformVariablesFile -NoNewline
    Write-Output 'Versioned foundation outputs were verified and merged into Terraform variables.'
}
finally { Remove-Item -LiteralPath $artifactPath -Force -ErrorAction SilentlyContinue }
