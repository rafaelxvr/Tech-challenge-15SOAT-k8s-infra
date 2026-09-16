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
function Require-ExactPropertyNames([object]$Object, [string[]]$Expected, [string]$Label) {
    $actualNames = @($Object.PSObject.Properties.Name | Sort-Object)
    $expectedNames = @($Expected | Sort-Object)
    if (($actualNames -join ',') -ne ($expectedNames -join ',')) { Fail "$Label does not match the complete schema-v1 field set." }
}
function Require-Text([object]$Object, [string]$Name) {
    $value = [string](OutputValue $Object $Name)
    if ([string]::IsNullOrWhiteSpace($value)) { Fail "foundation artifact has an empty '$Name'." }
    return $value
}
function Require-StringArray([object]$Object, [string]$Name) {
    $values = @(OutputValue $Object $Name)
    if ($values.Count -eq 0 -or @($values | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$_) }).Count -ne 0) { Fail "foundation artifact '$Name' must be a non-empty string array." }
    return $values
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
    Require-ExactPropertyNames $artifact @('schemaVersion', 'environment', 'sourceCommit', 'outputs') 'foundation artifact envelope'
    if ($artifact.schemaVersion -ne 1 -or [string](OutputValue $artifact 'environment') -cne 'foundation' -or [string](OutputValue $artifact 'sourceCommit') -cne $sourceCommit) { Fail 'foundation artifact schema, environment, or source commit is invalid.' }
    $outputs = OutputValue $artifact 'outputs'
    Require-ExactPropertyNames $outputs @('vpcId', 'privateSubnetIds', 'databaseSubnetIds', 'clusterName', 'clusterOidcProviderArn', 'vpcLinkId', 'backendListenerArns', 'codeBuildProjects') 'foundation artifact outputs'
    $null = Require-Text $outputs 'vpcId'
    $null = Require-StringArray $outputs 'privateSubnetIds'
    $null = Require-StringArray $outputs 'databaseSubnetIds'
    $null = Require-Text $outputs 'clusterName'
    $null = Require-Text $outputs 'clusterOidcProviderArn'
    $null = Require-Text $outputs 'vpcLinkId'
    $listeners = OutputValue $outputs 'backendListenerArns'
    $projects = OutputValue $outputs 'codeBuildProjects'
    Require-ExactPropertyNames $listeners @('staging', 'production') 'foundation backend listeners'
    $stagingListener = Require-Text $listeners 'staging'
    $productionListener = Require-Text $listeners 'production'
    $stagingRole = Require-Text (OutputValue $projects 'k8s_staging') 'roleArn'
    $productionRole = Require-Text (OutputValue $projects 'k8s_production') 'roleArn'

    $resolved = [ordered]@{}
    foreach ($property in $base.PSObject.Properties) { $resolved[$property.Name] = $property.Value }
    $resolved.foundation_outputs = [ordered]@{
        vpc_id                = Require-Text $outputs 'vpcId'
        cluster_name          = Require-Text $outputs 'clusterName'
        vpc_link_id           = Require-Text $outputs 'vpcLinkId'
        backend_listener_arns = [ordered]@{ staging = $stagingListener; production = $productionListener }
        codebuild_projects    = [ordered]@{ k8s_staging = [ordered]@{ roleArn = $stagingRole }; k8s_production = [ordered]@{ roleArn = $productionRole } }
    }
    $destination = Split-Path -Parent $OutputTerraformVariablesFile
    if ($destination -and -not (Test-Path -LiteralPath $destination)) { New-Item -ItemType Directory -Path $destination -Force | Out-Null }
    $resolved | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputTerraformVariablesFile -NoNewline
    Write-Output 'Versioned foundation outputs were verified and merged into Terraform variables.'
}
finally { Remove-Item -LiteralPath $artifactPath -Force -ErrorAction SilentlyContinue }
