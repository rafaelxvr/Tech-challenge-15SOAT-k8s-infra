Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. "$repo/scripts/staging-prerequisites-contract.ps1"
$temp=Join-Path ([IO.Path]::GetTempPath()) ('prerequisites-test-'+[guid]::NewGuid());New-Item -ItemType Directory $temp|Out-Null
$script:checks=0
function Assert([bool]$ok,$why){if(-not$ok){throw $why};$script:checks++}
function Reject([scriptblock]$action){try{& $action|Out-Null}catch{$script:checks++;return};throw 'Expected rejection'}
function Hash($path){(Get-FileHash $path).Hash.ToLowerInvariant()}
function Save($value,$path){$value|ConvertTo-Json -Depth 70 -Compress|Set-Content $path -NoNewline}
function aws {if($args[0] -cne 'sts'){throw 'No real AWS permitted'};$global:LASTEXITCODE=0;return '{"Account":"123456789012","Arn":"arn:aws:sts::123456789012:assumed-role/oficina-phase3-foundation-addons-role/test"}'}
function Invoke-MockedKube {
 $a=@($args);$global:LASTEXITCODE=0;$f=$global:prereqFixture;$f.calls.Add(($a-join ' '));$verb=$a[4]
 if($verb -ceq 'get'){
   if($a[5] -ceq 'namespace'){return '{"kind":"Namespace","metadata":{"name":"oficina-staging"},"status":{"phase":"Active"}}'}
   if($a[5] -ceq 'pods'){return '{"items":[]}'}
   if($f.failure -ceq 'null'){return 'null'}
   $key=$a[5]+'/'+$a[6];if($f.objects.ContainsKey($key)){return ($f.objects[$key]|ConvertTo-Json -Depth 70 -Compress)};return ''
 }
 if($verb -ceq 'create'){
   if($a -contains '--dry-run=server'){if($f.failure -ceq 'dry-run'){$global:LASTEXITCODE=1};return '{}'}
   if($f.failure -ceq 'race'){$global:LASTEXITCODE=1;return 'AlreadyExists'}
   $object=Get-Content $a[-1] -Raw|ConvertFrom-Json;$object.metadata|Add-Member uid ([guid]::NewGuid().ToString());$object.metadata|Add-Member resourceVersion '100'
   if($object.kind -ceq 'Service'){$object.spec|Add-Member clusterIP '10.100.0.1';$object.spec|Add-Member sessionAffinity 'None';$object.spec|Add-Member internalTrafficPolicy 'Cluster';$object.spec.ports[0]|Add-Member protocol 'TCP'}
   $f.objects[$object.kind+'/'+$object.metadata.name]=$object;return '{}'
 }
 throw 'Unexpected cluster operation'
}
function Fixture { $global:prereqFixture=@{objects=@{};calls=[Collections.Generic.List[string]]::new();failure=''} }
try{
 $commit='a'*40;$kcommit='b'*40
 $inputs=@{Environment='staging';Image=('123456789012.dkr.ecr.us-east-1.amazonaws.com/oficina-app@sha256:'+('a'*64));AppIrsaRoleArn='arn:aws:iam::123456789012:role/oficina-staging-app';DeployerPrincipalArn='arn:aws:iam::123456789012:role/oficina-app-deploy';PlatformBindingPrincipalArn='arn:aws:iam::123456789012:role/oficina-platform-binding';DbHost='db.oficina.internal';DbCidr='10.20.0.0/24';AlbSubnetCidrOne='10.42.0.0/24';AlbSubnetCidrTwo='10.42.1.0/24';AppSecretArn='arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/app-AbCdEf';AuthorizerTrustSecretArn='arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/authorizer-trust-AbCdEf';NewRelicIngestSecretArn='arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-AbCdEf';NewRelicAccountId='1234567';OutputDirectory=$temp}
 # render-platform invokes kubectl's executable directly (local kustomize only).
 $platform=& "$repo/scripts/render-platform.ps1" @inputs
 $sa=(Get-Content "$repo/k8s/platform/migration/service-account.json.tftpl" -Raw).Replace('${MIGRATION_IRSA_ROLE_ARN}','arn:aws:iam::123456789012:role/oficina-phase3-staging-migration')|ConvertFrom-Json
 $np=(Get-Content "$repo/k8s/platform/migration/network-policy.json.tftpl" -Raw).Replace('${DATABASE_PEERS}','[{"ipBlock":{"cidr":"10.42.64.0/24"}}]').Replace('${HTTPS_PEERS}','[{"ipBlock":{"cidr":"10.42.80.0/24"}}]')|ConvertFrom-Json
 Save $sa "$temp/migration-serviceaccount.json";Save $np "$temp/migration-network-policy.json"
 Save @{status='RENDERED_ONLY';environment='staging';sourceCommit=$commit;serviceAccountSha256=(Hash "$temp/migration-serviceaccount.json");networkPolicySha256=(Hash "$temp/migration-network-policy.json");migrationIdentitySha256=('c'*64)} "$temp/migration-render-receipt.json"
 Save @{apiVersion='v1';kind='ConfigMap';metadata=@{name='oficina-runtime-public-staging';namespace='oficina-staging'};data=@{'rds-ca.pem'='PUBLIC FIXTURE ONLY'}} "$temp/public.json"
 $arn='arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/oficina-phase3-staging-app/0123456789abcdef'
 Save @{environment=@{value='staging'};namespace=@{value='oficina-staging'};target_group_arn=@{value=$arn}} "$temp/outputs.json"
 $render=@{PlatformManifestFile=$platform;ExpectedPlatformSha256=(Hash $platform);MigrationDirectory=$temp;RuntimePublicConfigMapFile="$temp/public.json";ExpectedPublicSha256=(Hash "$temp/public.json");TerraformOutputsFile="$temp/outputs.json";ExpectedTerraformOutputsSha256=(Hash "$temp/outputs.json");TerraformOutputsBucket='fixture-artifact-bucket';TerraformOutputsKey="releases/k8s/staging/outputs/$kcommit.json";TerraformOutputsVersionId='reviewed-version';AppSourceCommit=$commit;K8sSourceCommit=$kcommit;OutputDirectory="$temp/rendered"}
 $path=& "$repo/scripts/render-staging-prerequisites.ps1" @render;$sha=Hash $path;$json=[IO.File]::ReadAllText($path);$bundle=Read-StagingPrerequisites $json $sha $commit
 Assert ($bundle.objects.Count -eq 8 -and $bundle.targetGroupArn -ceq $arn) 'Eight source objects must bind exact Terraform ARN'
 $second=& "$repo/scripts/render-staging-prerequisites.ps1" @render;Assert ((Hash $second) -ceq $sha) 'Rendering deterministic'
 foreach($field in @('TerraformOutputsVersionId','TerraformOutputsKey','ExpectedTerraformOutputsSha256')){$bad=$render.Clone();$bad[$field]='';Reject {& "$repo/scripts/render-staging-prerequisites.ps1" @bad}}
 New-Item -ItemType Directory "$temp/scripts"|Out-Null
 foreach($file in @('install-staging-prerequisites.ps1','staging-prerequisites-contract.ps1','check-cloud-window.ps1')){Copy-Item "$repo/scripts/$file" "$temp/scripts/$file"}
 'param($Action,$StateBucket,$OwnerToken);$global:prereqFixture.calls.Add("lock $Action")'|Set-Content "$temp/scripts/deployment-lock.ps1"
 'reviewed source'|Set-Content "$temp/source.zip"
 Save @{windowStartUtc=[DateTimeOffset]::UtcNow.AddHours(-1).ToString('o');windowEndUtc=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o');recordedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');accountEvidenceReference='review/fixture';projectAllowanceUsd=100;reserveUsd=10;currentEstimatedSpendUsd=1} "$temp/window.json"
 $run=@{Enabled='true';BundleFile=$path;ExpectedBundleSha256=$sha;AppSourceCommit=$commit;K8sSourceCommit=$kcommit;SourceArchiveFile="$temp/source.zip";ExpectedSourceSha256=(Hash "$temp/source.zip");CloudWindowEvidenceFile="$temp/window.json";ExpectedWindowSha256=(Hash "$temp/window.json");AccountId='123456789012';StateBucket='fixture-state-bucket';OutputDirectory="$temp/readback"}
 function kubectl {Invoke-MockedKube @args}
 $oldArn=$env:CODEBUILD_BUILD_ARN;$env:CODEBUILD_BUILD_ARN='arn:aws:codebuild:us-east-1:123456789012:build/oficina-phase3-foundation-addons:1234-abcd'
 Fixture;& "$temp/scripts/install-staging-prerequisites.ps1" @run|Out-Null;Assert ($global:prereqFixture.calls.Count -eq 0) 'Default validation must be offline'
 & "$temp/scripts/install-staging-prerequisites.ps1" @run -ExecuteReviewedCreation|Out-Null
 Assert ($global:prereqFixture.objects.Count -eq 8) 'Must create eight prerequisites only'
 $receipt=Get-Content "$temp/readback/platform-prerequisites-readback.json" -Raw|ConvertFrom-Json;Assert-PrerequisiteReceipt $receipt $bundle $sha;$script:checks++
 $global:prereqFixture.calls.Clear();& "$temp/scripts/install-staging-prerequisites.ps1" @run -ExecuteReviewedCreation|Out-Null
 Assert (-not(($global:prereqFixture.calls-join "`n") -match 'create|patch|delete|apply')) 'Matching existing bundle must be read-only'
 $keep=$global:prereqFixture.objects['Service/oficina-app'];Fixture;$global:prereqFixture.objects['Service/oficina-app']=$keep;Reject {& "$temp/scripts/install-staging-prerequisites.ps1" @run -ExecuteReviewedCreation}
 Assert (-not(($global:prereqFixture.calls-join "`n") -match 'create|patch|delete|apply')) 'Partial bundle must stop without writes'
 foreach($failure in @('null','dry-run','race')){Fixture;$global:prereqFixture.failure=$failure;Reject {& "$temp/scripts/install-staging-prerequisites.ps1" @run -ExecuteReviewedCreation};Assert ($global:prereqFixture.objects.Count -eq 0) 'Failure/race cannot create or overwrite objects'}
 $prepare=@{Enabled='true';AccountId='123456789012';ArtifactBucket='fixture-artifact-bucket';StateBucket='fixture-state-bucket';SourceVersionId='source-version';SourceSha256=$run.ExpectedSourceSha256;K8sSourceCommit=$kcommit;AppSourceCommit=$commit;BundleFile=$path;BundleSha256=$sha;BundleVersionId='bundle-version';WindowFile="$temp/window.json";WindowSha256=$run.ExpectedWindowSha256;WindowVersionId='window-version';OutputDirectory="$temp/payload"}
 Reject {& "$repo/scripts/prepare-staging-prerequisites-execution.ps1" @prepare}
 & "$repo/scripts/prepare-staging-prerequisites-execution.ps1" @prepare -CreateReviewedObjects|Out-Null
 $payload=Get-Content "$temp/payload/start-build.json" -Raw|ConvertFrom-Json
 Assert ($payload.projectName -ceq 'oficina-phase3-foundation-addons' -and [Text.Encoding]::UTF8.GetByteCount($payload.buildspecOverride) -lt 25600) 'Exact private executor and bounded override required'
 $runner=Get-Content "$temp/payload/decoded-runner.ps1" -Raw
 Assert ($runner -notmatch 'terraform|start-build|update-project|kubectl apply|delete-access-entry' -and $runner.Contains('Receive "foundation-addons/manifests/staging/')) 'Dedicated override must never run addon Terraform or another project'
 $prepare.BundleVersionId='null';Reject {& "$repo/scripts/prepare-staging-prerequisites-execution.ps1" @prepare -CreateReviewedObjects}
 Write-Output "PASS: $script:checks source renderer/create-only/partial/drift contracts; boundaries mocked."
}finally{
 if(Get-Variable oldArn -ErrorAction SilentlyContinue){$env:CODEBUILD_BUILD_ARN=$oldArn}
 if(-not[IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup'}
 Remove-Item -LiteralPath $temp -Recurse -Force
}
