[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BindingBase64,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$SourceCommit,
    [Parameter(Mandatory)][string]$ExpectedSourceSha256,
    [Parameter(Mandatory)][string]$ExpectedManifestSha256,
    [Parameter(Mandatory)][string]$ExpectedTerraformVariablesSha256,
    [Parameter(Mandatory)][string]$ExpectedDeployerImageDigest
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Fail([string]$Code) { throw "PRODUCTION_TRANSPORT_$Code" }
function Text([object]$Object,[string]$Name) {
    $p=$Object.PSObject.Properties[$Name]
    if($null -eq $p -or $p.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($p.Value) -or $p.Value -ceq 'null'){Fail 'SCALAR_REQUIRED'}
    return $p.Value
}
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Pinned([string]$Path,[string]$Digest) {
    if($Digest -cnotmatch '\A[a-f0-9]{64}\z' -or -not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Hash $Path) -cne $Digest){Fail 'HASH_MISMATCH'}
}
function Expand-BoundedArchive([string]$Archive,[string]$Destination) {
    if(Test-Path -LiteralPath $Destination){Fail 'EXTRACTION_TARGET_EXISTS'}
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $total=0L
        if($zip.Entries.Count -gt 10000){Fail 'ARCHIVE_LIMIT'}
        foreach($entry in $zip.Entries) {
            $path=$entry.FullName
            $total+=$entry.Length
            if($total -gt 1GB -or $path -match '\\|:|\A/|[\x00-\x1f]' -or
                @($path.TrimEnd('/').Split('/')|Where-Object {$_ -cin @('','..','.')}).Count -gt 0 -or
                -not $paths.Add($path.TrimEnd('/')) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){Fail 'UNSAFE_ARCHIVE'}
        }
    } finally {$zip.Dispose()}
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive,$Destination)
}
$binding=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($BindingBase64))|ConvertFrom-Json
if($binding.enabled -isnot [bool] -or -not $binding.enabled){Fail 'DISABLED'}
if($binding.launcher_enabled -isnot [bool]){Fail 'GATE_INVALID'}
$repository=Text $binding 'repository'
$owner=switch($repository){'oficina-app' {'app'} 'oficina-functions' {'functions'} default {Fail 'REPOSITORY_INVALID'}}
$prefix="releases/$owner/production"
if((Text $binding 'environment') -cne 'production' -or (Text $binding 'source_prefix') -cne $prefix -or
    (Text $binding 'source_commit') -cne $SourceCommit -or $SourceCommit -cnotmatch '\A[a-f0-9]{40}\z' -or
    (Text $binding 'state_key') -cne "$owner/production.tfstate" -or
    (Text $binding 'tfvars_path') -cne "/tmp/oficina/${owner}_production.tfvars.json" -or
    (Text $binding 'region') -cne 'us-east-1' -or (Text $binding 'deployment_mode') -cnotin @('plan','apply') -or
    (Text $binding 'review_object_key') -cne "$prefix/reviews/$SourceCommit/inputs.zip" -or
    (Text $binding 'deployer_image_digest') -cne $ExpectedDeployerImageDigest){Fail 'CONTEXT_MISMATCH'}
$account=Text $binding 'account_id';$role=Text $binding 'role_arn'
if($account -cnotmatch '\A[0-9]{12}\z' -or $role -cnotmatch "\Aarn:aws:iam::${account}:role/[A-Za-z0-9+=,.@_/-]*production[A-Za-z0-9+=,.@_/-]*\z"){Fail 'ROLE_MISMATCH'}
$source=Join-Path $WorkDirectory 'bundle.zip';$manifest=Join-Path $WorkDirectory 'release-manifest.json'
Pinned $source $ExpectedSourceSha256;Pinned $manifest $ExpectedManifestSha256;Pinned $binding.tfvars_path $ExpectedTerraformVariablesSha256
$archive=Join-Path $WorkDirectory 'production-review.zip'
$global:LASTEXITCODE=0
& aws s3api get-object --bucket (Text $binding 'artifact_bucket') --key $binding.review_object_key --version-id (Text $binding 'review_version_id') $archive *> $null
if($LASTEXITCODE -ne 0){Fail 'DOWNLOAD_FAILED'}
Pinned $archive (Text $binding 'review_sha256')
$inputRoot=Join-Path $WorkDirectory 'production-review'
Expand-BoundedArchive $archive $inputRoot
$inputsFile=Join-Path $inputRoot 'production-inputs.json'
Pinned $inputsFile (Text $binding 'inputs_sha256')
$inputs=Get-Content -LiteralPath $inputsFile -Raw|ConvertFrom-Json
foreach($entry in @{environment='production';sourceCommit=$SourceCommit;roleArn=$role;accountId=$account;stateBucket=$binding.state_bucket;projectName=$binding.project_name;sourcePrefix=$prefix;deployerImageDigest=$ExpectedDeployerImageDigest}.GetEnumerator()) {
    if((Text $inputs $entry.Key) -cne $entry.Value){Fail 'INPUT_BINDING_MISMATCH'}
}
function Input-File([string]$Field) {
    $reference=$inputs.PSObject.Properties[$Field]
    if($null -eq $reference -or $reference.Value -isnot [pscustomobject]){Fail 'INPUT_REFERENCE_INVALID'}
    $name=Text $reference.Value 'path'
    if([IO.Path]::IsPathRooted($name) -or $name -match '\\|:'){Fail 'INPUT_PATH_INVALID'}
    $path=[IO.Path]::GetFullPath((Join-Path $inputRoot $name))
    if(-not $path.StartsWith([IO.Path]::GetFullPath($inputRoot)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal)){Fail 'INPUT_PATH_INVALID'}
    Pinned $path (Text $reference.Value 'sha256')
    return $path
}
foreach($pair in @{sourceArchive=$ExpectedSourceSha256;releaseManifest=$ExpectedManifestSha256;terraformVariables=$ExpectedTerraformVariablesSha256}.GetEnumerator()) {
    if((Hash (Input-File $pair.Key)) -cne $pair.Value){Fail 'OUTER_BINDING_MISMATCH'}
}
$null=Input-File 'cloudWindowEvidence';$null=Input-File 'stagingPromotion'
if($owner -ceq 'app'){$null=Input-File 'platformInputs';$null=Input-File 'stagingReleaseManifest'}
Expand-BoundedArchive $source (Join-Path $WorkDirectory 'release')
$entrypoint=Join-Path $WorkDirectory 'release/scripts/deploy.ps1'
if(-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)){Fail 'ENTRYPOINT_MISSING'}
$argsMap=@{Environment='production';ReleaseManifest=$manifest;ExpectedSourceSha256=$ExpectedSourceSha256;ExpectedManifestSha256=$ExpectedManifestSha256;
    SourceCommit=$SourceCommit;ExpectedDeployerImageDigest=$ExpectedDeployerImageDigest;TerraformVariablesFile=$binding.tfvars_path;
    TerraformBackendBucket=$binding.state_bucket;TerraformBackendKey=$binding.state_key;TerraformBackendLockKey="$($binding.state_key).tflock";TerraformBackendRegion=$binding.region;
    StateBucket=$binding.state_bucket;ProductionEnabled='true';ProtectedEnvironment='production';ProductionInputsFile=$inputsFile;
    ExpectedProductionInputsSha256=$binding.inputs_sha256;ProductionRoleArn=$role;EventName='push';BranchRef='refs/heads/main'}
$launcher=$binding.launcher_enabled.ToString().ToLowerInvariant()
if($owner -ceq 'app') {
    $argsMap.ProductionRuntimeEnabled=$launcher;$argsMap.SourceArchiveFile=$source;$argsMap.SourceKey="$prefix/bundle.zip"
} else {
    $argsMap.ProductionLauncherEnabled=$launcher;$argsMap.ExpectedTerraformVariablesSha256=$ExpectedTerraformVariablesSha256;$argsMap.SharedFoundationMutation=$true
}
# Source-owned validation binds the staging receipt, release, images and window.
# No Kubernetes identity/configuration is acquired on this validation-only path.
$global:LASTEXITCODE=0
& $entrypoint @argsMap -DryRun
if($LASTEXITCODE -ne 0){Fail 'PREFLIGHT_FAILED'}
if($binding.deployment_mode -cne 'apply' -or -not $binding.launcher_enabled){return}
if($owner -ceq 'app') {
    $release=Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json
    if((Text $release 'kubeContext') -cne (Text $binding 'cluster_arn')){Fail 'CLUSTER_MISMATCH'}
    $env:KUBECONFIG=Join-Path $WorkDirectory 'production-kubeconfig'
    & aws eks update-kubeconfig --region $binding.region --name ($binding.cluster_arn.Split('/')[-1]) --kubeconfig $env:KUBECONFIG *> $null
    if($LASTEXITCODE -ne 0){Fail 'CLUSTER_CONFIGURATION_FAILED'}
}
$global:LASTEXITCODE=0
& $entrypoint @argsMap -ApplyReviewedPlan
if($LASTEXITCODE -ne 0){Fail 'EXECUTION_FAILED'}
