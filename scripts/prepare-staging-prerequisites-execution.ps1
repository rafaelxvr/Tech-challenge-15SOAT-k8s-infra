[CmdletBinding()]
param([string]$Enabled='', [switch]$CreateReviewedObjects,
[Parameter(Mandatory)][ValidatePattern('^[0-9]{12}$')][string]$AccountId,[Parameter(Mandatory)][string]$ArtifactBucket,[Parameter(Mandatory)][string]$StateBucket,
[Parameter(Mandatory)][string]$SourceVersionId,[Parameter(Mandatory)][string]$SourceSha256,[Parameter(Mandatory)][string]$K8sSourceCommit,
[Parameter(Mandatory)][string]$AppSourceCommit,[Parameter(Mandatory)][string]$BundleFile,[Parameter(Mandatory)][string]$BundleSha256,[Parameter(Mandatory)][string]$BundleVersionId,
[Parameter(Mandatory)][string]$WindowFile,[Parameter(Mandatory)][string]$WindowSha256,[Parameter(Mandatory)][string]$WindowVersionId,[Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
. "$PSScriptRoot/staging-prerequisites-contract.ps1"
if($Enabled -cne 'true' -or -not $CreateReviewedObjects){throw 'STAGING_PREREQUISITES_EXECUTION_DISABLED'}
$bundle=Read-StagingPrerequisites ([IO.File]::ReadAllText($BundleFile)) $BundleSha256 $AppSourceCommit
foreach($value in @($SourceVersionId,$BundleVersionId,$WindowVersionId)){if([string]::IsNullOrWhiteSpace($value) -or $value -ceq 'null'){throw 'Immutable VersionId required'}}
if($bundle.k8sSourceCommit -cne $K8sSourceCommit -or $SourceSha256 -cnotmatch '^[a-f0-9]{64}$' -or $WindowSha256 -cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash $WindowFile).Hash.ToLowerInvariant() -cne $WindowSha256 -or $ArtifactBucket -cnotmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' -or $StateBucket -cnotmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$'){throw 'Unreviewed execution input'}
& "$PSScriptRoot/check-cloud-window.ps1" -Environment staging -EvidenceFile $WindowFile|Out-Null
$inputs=@{account=$AccountId;artifactBucket=$ArtifactBucket;stateBucket=$StateBucket;sourceVersion=$SourceVersionId;sourceSha=$SourceSha256;k8sCommit=$K8sSourceCommit;appCommit=$AppSourceCommit;bundleSha=$BundleSha256;bundleVersion=$BundleVersionId;windowSha=$WindowSha256;windowVersion=$WindowVersionId}
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($inputs|ConvertTo-Json -Compress)))
$runner=@'
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$i=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__INPUTS__'))|ConvertFrom-Json
$work=Join-Path ([IO.Path]::GetTempPath()) ('staging-prerequisites-'+[guid]::NewGuid());New-Item -ItemType Directory $work|Out-Null
function Receive($key,$version,$sha,$path){$response=& aws s3api get-object --bucket $i.artifactBucket --key $key --version-id $version $path --output json 2>$null;if($LASTEXITCODE -ne 0){throw 'Input download failed'};$response=($response-join "`n")|ConvertFrom-Json;if($response.VersionId -cne $version -or (Get-FileHash $path).Hash.ToLowerInvariant() -cne $sha){throw 'Input VersionId/hash mismatch'}}
Receive 'foundation-addons/bundle.zip' $i.sourceVersion $i.sourceSha "$work/source.zip"
Receive "foundation-addons/manifests/staging/$($i.appCommit)/prerequisites.json" $i.bundleVersion $i.bundleSha "$work/prerequisites.json"
Receive "foundation-addons/manifests/staging/$($i.appCommit)/cloud-window.json" $i.windowVersion $i.windowSha "$work/window.json"
Expand-Archive -LiteralPath "$work/source.zip" -DestinationPath "$work/source"
if(-not(Test-Path "$work/source/scripts/install-staging-prerequisites.ps1" -PathType Leaf)){throw 'Reviewed source entrypoint missing'}
& aws eks update-kubeconfig --name oficina-phase3 --region us-east-1 --alias "arn:aws:eks:us-east-1:$($i.account):cluster/oficina-phase3" 2>$null|Out-Null
if($LASTEXITCODE -ne 0){throw 'Private kubeconfig failed'}
& "$work/source/scripts/install-staging-prerequisites.ps1" -Enabled true -ExecuteReviewedCreation -BundleFile "$work/prerequisites.json" -ExpectedBundleSha256 $i.bundleSha -AppSourceCommit $i.appCommit -K8sSourceCommit $i.k8sCommit -SourceArchiveFile "$work/source.zip" -ExpectedSourceSha256 $i.sourceSha -CloudWindowEvidenceFile "$work/window.json" -ExpectedWindowSha256 $i.windowSha -AccountId $i.account -StateBucket $i.stateBucket -OutputDirectory "$work/receipt"
'@.Replace('__INPUTS__',$encoded)
$command='pwsh -NoLogo -NoProfile -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($runner))
$buildspec=@{version='0.2';phases=@{build=@{commands=@($command)}}}|ConvertTo-Json -Depth 6 -Compress
if([Text.Encoding]::UTF8.GetByteCount($buildspec) -gt 25600){throw 'Buildspec override exceeds limit'}
New-Item -ItemType Directory $OutputDirectory -Force|Out-Null
$payload=@{projectName='oficina-phase3-foundation-addons';sourceVersion=$SourceVersionId;buildspecOverride=$buildspec}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'start-build.json'),($payload|ConvertTo-Json -Depth 8 -Compress))
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'decoded-runner.ps1'),$runner)
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'buildspec.json'),$buildspec)
Write-Output 'REVIEW_ONLY: payload prepared; no AWS command or build was executed.'
