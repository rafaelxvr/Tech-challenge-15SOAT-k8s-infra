[CmdletBinding()]
param([string]$Enabled='', [switch]$ExecuteReviewedCreation,
[Parameter(Mandatory)][string]$BundleFile,[Parameter(Mandatory)][string]$ExpectedBundleSha256,[Parameter(Mandatory)][string]$AppSourceCommit,
[Parameter(Mandatory)][string]$K8sSourceCommit,[Parameter(Mandatory)][string]$SourceArchiveFile,[Parameter(Mandatory)][string]$ExpectedSourceSha256,
[Parameter(Mandatory)][string]$CloudWindowEvidenceFile,[Parameter(Mandatory)][string]$ExpectedWindowSha256,
[Parameter(Mandatory)][ValidatePattern('^[0-9]{12}$')][string]$AccountId,[Parameter(Mandatory)][string]$StateBucket,
[Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
. "$PSScriptRoot/staging-prerequisites-contract.ps1"
function Hash($path){(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
function Assert-CreateAuthorization([string]$ObjectPath,$ExpectedObject){
 if((Hash $BundleFile) -cne $ExpectedBundleSha256 -or (Hash $SourceArchiveFile) -cne $ExpectedSourceSha256 -or
    (Hash $CloudWindowEvidenceFile) -cne $ExpectedWindowSha256 -or
    (Hash $ObjectPath) -cne (Get-PrerequisiteHash ($ExpectedObject|ConvertTo-Json -Depth 70 -Compress))){throw 'PREREQUISITES_CREATE_INPUT_DRIFT'}
 & "$PSScriptRoot/check-cloud-window.ps1" -EvidenceFile $CloudWindowEvidenceFile -Environment staging|Out-Null
 if((Hash $CloudWindowEvidenceFile) -cne $ExpectedWindowSha256){throw 'PREREQUISITES_CREATE_WINDOW_DRIFT'}
}
if($Enabled -cne 'true'){throw 'STAGING_PREREQUISITES_DISABLED'}
$bundle=Read-StagingPrerequisites ([IO.File]::ReadAllText($BundleFile)) $ExpectedBundleSha256 $AppSourceCommit
if($bundle.k8sSourceCommit -cne $K8sSourceCommit -or (Hash $SourceArchiveFile) -cne $ExpectedSourceSha256 -or $ExpectedSourceSha256 -cnotmatch '^[a-f0-9]{64}$' -or
 (Hash $CloudWindowEvidenceFile) -cne $ExpectedWindowSha256 -or $ExpectedWindowSha256 -cnotmatch '^[a-f0-9]{64}$' -or $bundle.targetGroupArn -cnotmatch "^arn:aws:elasticloadbalancing:us-east-1:${AccountId}:" -or $StateBucket -cnotmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$'){throw 'PREREQUISITES_EXECUTOR_INPUT_MISMATCH'}
& "$PSScriptRoot/check-cloud-window.ps1" -EvidenceFile $CloudWindowEvidenceFile -Environment staging|Out-Null
if(-not $ExecuteReviewedCreation){Write-Output 'INPUTS_VALIDATED_DEPLOYMENT_DISABLED';return}
if($env:CODEBUILD_BUILD_ARN -cnotmatch "^arn:aws:codebuild:us-east-1:${AccountId}:build/oficina-phase3-foundation-addons:[a-f0-9-]+$"){throw 'FOUNDATION_PRIVATE_EXECUTOR_REQUIRED'}
$identity=& aws sts get-caller-identity --output json 2>$null;if($LASTEXITCODE -ne 0){throw 'FOUNDATION_IDENTITY_READ_FAILED'};$identity=($identity-join "`n")|ConvertFrom-Json
if($identity.Account -cne $AccountId -or $identity.Arn -cnotmatch "^arn:aws:sts::${AccountId}:assumed-role/oficina-phase3-foundation-addons-role/[^/]+$"){throw 'FOUNDATION_IDENTITY_MISMATCH'}
$context="arn:aws:eks:us-east-1:${AccountId}:cluster/oficina-phase3"
function Kube([string[]]$Arguments){$result=& kubectl --context $context --namespace oficina-staging @Arguments 2>$null;if($LASTEXITCODE -ne 0){throw 'PREREQUISITES_CLUSTER_OPERATION_FAILED'};return ($result-join "`n")}
function ReadObject($expected){$json=Kube @('get',$expected.kind,$expected.metadata.name,'--ignore-not-found=true','-o','json');if([string]::IsNullOrWhiteSpace($json)){return $null};$actual=ConvertFrom-Json -InputObject $json -NoEnumerate;Assert-PrerequisiteReadback $actual $expected;return $actual}
$owner=[guid]::NewGuid().ToString();$locked=$false
New-Item -ItemType Directory $OutputDirectory -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'platform-prerequisites-readback.json'),'{"status":"EXECUTION_PENDING","environment":"staging"}')
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'create-responses.json'),'[]')
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'created-objects.json'),'[]')
$createResponses=@()
try{
 & "$PSScriptRoot/deployment-lock.ps1" -Action Acquire -StateBucket $StateBucket -OwnerToken $owner|Out-Null;$locked=$true
 $namespace=(Kube @('get','namespace','oficina-staging','-o','json'))|ConvertFrom-Json
 if($namespace.kind -cne 'Namespace' -or $namespace.metadata.name -cne 'oficina-staging' -or $namespace.status.phase -cne 'Active'){throw 'ACTIVE_STAGING_NAMESPACE_REQUIRED'}
 $readback=@();$absent=0
 foreach($object in $bundle.objects){$actual=ReadObject $object;if($null -eq $actual){$absent++}else{$readback+=$actual}}
 if($absent -ne 0 -and $absent -ne 8){throw 'PARTIAL_PREREQUISITES_STOP_REVIEW_REQUIRED'}
 $status='EXISTING_VERIFIED'
 if($absent -eq 8){
   $pods=(Kube @('get','pods','-o','json'))|ConvertFrom-Json;if($pods.items -isnot [array] -or $pods.items.Count -ne 0){throw 'FRESH_NAMESPACE_PODS_REQUIRE_REVIEW'}
   foreach($object in $bundle.objects){$path=Join-Path $OutputDirectory "$($object.kind)-$($object.metadata.name).json";[IO.File]::WriteAllText($path,($object|ConvertTo-Json -Depth 70 -Compress));$null=Kube @('create','--dry-run=server','-f',$path)}
   & "$PSScriptRoot/check-cloud-window.ps1" -EvidenceFile $CloudWindowEvidenceFile -Environment staging|Out-Null
   # Recheck all objects after admission dry-run; CREATE still rejects any later race.
   foreach($object in $bundle.objects){if($null -ne (ReadObject $object)){throw 'PREREQUISITES_CONCURRENT_CREATION_STOP'}}
   foreach($object in $bundle.objects){
     $path=Join-Path $OutputDirectory "$($object.kind)-$($object.metadata.name).json"
     # This guard is intentionally inside the mutation loop: earlier admission
     # checks cannot authorize a later CREATE after expiry or input replacement.
     Assert-CreateAuthorization $path $object
     $created=ConvertFrom-Json -InputObject (Kube @('create','-f',$path,'-o','json')) -NoEnumerate
     # Preserve the API response before semantic checks or GET; this file is
     # unverified creation evidence, never automatic rollback authorization.
     $createResponses+=$created
     [IO.File]::WriteAllText((Join-Path $OutputDirectory 'create-responses.json'),(ConvertTo-Json -InputObject $createResponses -Depth 70))
     Assert-PrerequisiteReadback $created $object
     $actual=ReadObject $object;if($null -eq $actual){throw 'PREREQUISITES_CREATE_READBACK_MISSING'}
     if($actual.metadata.uid -cne $created.metadata.uid){throw 'PREREQUISITES_CREATE_READBACK_UID_MISMATCH'}
     $readback+=$actual
     # Preserve partial ownership evidence without automatically deleting anything.
     [IO.File]::WriteAllText((Join-Path $OutputDirectory 'created-objects.json'),(ConvertTo-Json -InputObject $readback -Depth 70))
   };$status='CREATED_VERIFIED'
 }
 $receipt=[pscustomobject]@{schemaVersion=1;environment='staging';appSourceCommit=$AppSourceCommit;k8sSourceCommit=$K8sSourceCommit;bundleSha256=$ExpectedBundleSha256;sourceSha256=$ExpectedSourceSha256;windowSha256=$ExpectedWindowSha256;status=$status;objects=$readback;creationResponses=$createResponses;completedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
 Assert-PrerequisiteReceipt $receipt $bundle $ExpectedBundleSha256
 [IO.File]::WriteAllText((Join-Path $OutputDirectory 'platform-prerequisites-readback.json'),($receipt|ConvertTo-Json -Depth 70 -Compress))
 Write-Output 'PREREQUISITES_READBACK_JSON_BEGIN';Write-Output ($receipt|ConvertTo-Json -Depth 70 -Compress);Write-Output 'PREREQUISITES_READBACK_JSON_END'
}finally{if($locked){& "$PSScriptRoot/deployment-lock.ps1" -Action Release -StateBucket $StateBucket -OwnerToken $owner|Out-Null}}
