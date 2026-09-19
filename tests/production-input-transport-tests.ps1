[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$transport=Join-Path $repo 'infra/modules/deployment-executor/production-input-transport.ps1'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('oficina-production-transport-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $temp|Out-Null
$global:transportFixture=@{Calls=[Collections.Generic.List[string]]::new();Invocations=[Collections.Generic.List[object]]::new();Failure=''}
$script:count=0;$created=[Collections.Generic.List[string]]::new()
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:count++}
function Reject([scriptblock]$Action){try{& $Action|Out-Null}catch{$script:count++;return};throw 'Expected transport rejection'}
function Hash($Path){(Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Save($Value,$Path){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))}
function aws {
    $f=$global:transportFixture;$a=@($args);$f.Calls.Add($a -join ' ');$global:LASTEXITCODE=0
    if($a[0] -ceq 's3api' -and $a[1] -ceq 'get-object'){
        if($a[$a.IndexOf('--key')+1] -cne $f.Key -or $a[$a.IndexOf('--version-id')+1] -cne 'immutable-version'){throw 'Unpinned review download'}
        Copy-Item -LiteralPath $f.Archive -Destination $a[-1];return '{}'
    }
    if($a[0] -ceq 'eks' -and $a[1] -ceq 'update-kubeconfig'){return '{}'}
    throw 'Unexpected AWS operation in offline mock'
}
function Reset([string]$Owner='app') {
    $script:work=Join-Path $temp ([guid]::NewGuid().ToString());New-Item -ItemType Directory $work|Out-Null
    $script:reviewRoot=Join-Path $work 'review-source';New-Item -ItemType Directory $reviewRoot|Out-Null
    $sourceRoot=Join-Path $work 'source';New-Item -ItemType Directory (Join-Path $sourceRoot 'scripts') -Force|Out-Null
    $stub=@'
param([switch]$DryRun,[switch]$ApplyReviewedPlan,[Parameter(ValueFromRemainingArguments=$true)][object[]]$Rest)
$global:transportFixture.Invocations.Add(@{DryRun=[bool]$DryRun;Apply=[bool]$ApplyReviewedPlan;Arguments=($Rest -join ' ')})
if($global:transportFixture.Failure -ceq 'preflight' -and $DryRun){$global:LASTEXITCODE=1;return}
'@
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'scripts/deploy.ps1'),$stub)
    [IO.Compression.ZipFile]::CreateFromDirectory($sourceRoot,(Join-Path $work 'bundle.zip'))
    $script:trusted="/tmp/oficina/${Owner}_production.tfvars.json"
    if(-not $created.Contains($trusted)){
        if(Test-Path $trusted){throw 'Refusing to overwrite pre-existing trusted tfvars'}
        New-Item -ItemType Directory (Split-Path -Parent $trusted) -Force|Out-Null;$created.Add($trusted)
    }
    Save @{environment='production'} $trusted
    $commit='a'*40;$deployer='sha256:'+('b'*64)
    Save @{environment='production';sourceCommit=$commit;kubeContext='arn:aws:eks:us-east-1:123456789012:cluster/oficina-phase3'} (Join-Path $work 'release-manifest.json')
    Copy-Item (Join-Path $work 'bundle.zip') (Join-Path $reviewRoot 'source.zip')
    Copy-Item (Join-Path $work 'release-manifest.json') (Join-Path $reviewRoot 'release.json')
    Copy-Item $trusted (Join-Path $reviewRoot 'tfvars.json')
    $script:inputs=@{environment='production';sourceCommit=$commit;roleArn="arn:aws:iam::123456789012:role/oficina-$Owner-production-launcher";accountId='123456789012';stateBucket='state-fixture';projectName="oficina-phase3-oficina-$Owner-production-deploy";sourcePrefix="releases/$Owner/production";deployerImageDigest=$deployer}
    foreach($pair in @{sourceArchive='source.zip';releaseManifest='release.json';terraformVariables='tfvars.json';cloudWindowEvidence='window.json';stagingPromotion='staging-receipt.json';platformInputs='platform.json';stagingReleaseManifest='staging-release.json'}.GetEnumerator()){
        $path=Join-Path $reviewRoot $pair.Value
        if(-not (Test-Path $path)){Save @{offline=$true} $path}
        $inputs[$pair.Key]=@{path=$pair.Value;sha256=(Hash $path)}
    }
    $script:binding=@{enabled=$true;launcher_enabled=$false;repository="oficina-$Owner";environment='production';source_prefix=$inputs.sourcePrefix;source_commit=$commit;state_key="$Owner/production.tfstate";tfvars_path=$trusted;region='us-east-1';deployment_mode='plan';review_object_key="releases/$Owner/production/reviews/$commit/inputs.zip";review_version_id='immutable-version';deployer_image_digest=$deployer;account_id='123456789012';role_arn=$inputs.roleArn;artifact_bucket='artifact-fixture';state_bucket='state-fixture';project_name=$inputs.projectName;cluster_arn='arn:aws:eks:us-east-1:123456789012:cluster/oficina-phase3'}
    $script:arguments=@{WorkDirectory=$work;SourceCommit=$commit;ExpectedSourceSha256=(Hash (Join-Path $work 'bundle.zip'));ExpectedManifestSha256=(Hash (Join-Path $work 'release-manifest.json'));ExpectedTerraformVariablesSha256=(Hash $trusted);ExpectedDeployerImageDigest=$deployer}
    $global:transportFixture.Calls.Clear();$global:transportFixture.Invocations.Clear();$global:transportFixture.Failure=''
}
function Seal {
    Save $inputs (Join-Path $reviewRoot 'production-inputs.json')
    $archive=Join-Path $work 'fixture-review.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($reviewRoot,$archive)
    $binding.review_sha256=Hash $archive;$binding.inputs_sha256=Hash (Join-Path $reviewRoot 'production-inputs.json')
    $global:transportFixture.Archive=$archive;$global:transportFixture.Key=$binding.review_object_key
}
function Run {
    $arguments.BindingBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($binding|ConvertTo-Json -Depth 10)))
    & $transport @arguments
}
try {
    foreach($owner in @('app','functions')) {
        Reset $owner;Seal;Run
        Assert ($global:transportFixture.Invocations.Count -eq 1 -and $global:transportFixture.Invocations[0].DryRun) 'Default path must only preflight'
        Assert ($global:transportFixture.Calls.Count -eq 1) 'Preflight may only read the exact review object'
        $argsText=$global:transportFixture.Invocations[0].Arguments
        Assert ($argsText -match 'ProductionEnabled[: ]+true' -and $argsText -match 'ProtectedEnvironment[: ]+production' -and $argsText -match 'ProductionRoleArn' -and $argsText -match 'refs/heads/main') 'Reviewed context and role must reach source adapter'
        Reset $owner;$binding.deployment_mode='apply';Seal;Run
        Assert ($global:transportFixture.Invocations.Count -eq 1) 'Apply mode alone cannot enable launcher'
        Reset $owner;$binding.launcher_enabled=$true;Seal;Run
        Assert ($global:transportFixture.Invocations.Count -eq 1) 'Launcher gate alone cannot enable apply'
        Reset $owner;$binding.launcher_enabled=$true;$binding.deployment_mode='apply';Seal;Run
        Assert ($global:transportFixture.Invocations.Count -eq 2 -and $global:transportFixture.Invocations[1].Apply) 'Explicit reviewed gates must reach apply adapter'
        Assert ($global:transportFixture.Calls.Count -eq $(if($owner -ceq 'app'){2}else{1})) 'Only explicitly executing APP may configure Kubernetes context'
        $argsText=$global:transportFixture.Invocations[1].Arguments
        Assert ($argsText -match $(if($owner -ceq 'app'){'ProductionRuntimeEnabled.*true'}else{'ProductionLauncherEnabled.*true'}) -and $argsText -match 'StateBucket.*state-fixture') 'Owner-specific runtime gate/shared lock bucket missing'
    }
    foreach($change in @(
        {$binding.enabled=$false},{$binding.launcher_enabled='true'},{$binding.environment='staging'},{$binding.repository='oficina-db-infra'},
        {$binding.source_prefix='releases/app/staging'},{$binding.source_commit='c'*40},{$binding.state_key='app/staging.tfstate'},
        {$binding.tfvars_path='/tmp/oficina/app_staging.tfvars.json'},{$binding.role_arn='arn:aws:iam::999999999999:role/app-production'},
        {$binding.review_object_key='releases/app/staging/inputs.zip'},{$arguments.ExpectedSourceSha256='0'*64},{$binding.deployer_image_digest='sha256:'+('f'*64)}
    )){Reset;Seal;& $change;Reject {Run};Assert ($global:transportFixture.Calls.Count -eq 0) 'Invalid binding must fail before AWS'}
    foreach($change in @({$inputs.roleArn='arn:aws:iam::123456789012:role/staging'},{$inputs.stateBucket='other-state'},{$inputs.environment='staging'},{$inputs.sourceArchive.path='../bundle.zip'},{$inputs.stagingPromotion.sha256='0'*64})){
        Reset;& $change;Seal;Reject {Run};Assert ($global:transportFixture.Invocations.Count -eq 0) 'Invalid review must never invoke source'
    }
    foreach($field in @('review_sha256','inputs_sha256')){Reset;Seal;$binding[$field]='0'*64;Reject {Run};Assert ($global:transportFixture.Invocations.Count -eq 0) 'Digest mismatch reached adapter'}
    Reset;Seal;$global:transportFixture.Failure='preflight';$binding.launcher_enabled=$true;$binding.deployment_mode='apply';Reject {Run}
    Assert ($global:transportFixture.Invocations.Count -eq 1 -and $global:transportFixture.Calls.Count -eq 1) 'Failed preflight cannot configure cluster or apply'
    Reset;Seal
    $zip=[IO.Compression.ZipFile]::Open($global:transportFixture.Archive,[IO.Compression.ZipArchiveMode]::Update)
    try{$null=$zip.CreateEntry('../escape.txt')}finally{$zip.Dispose()}
    $binding.review_sha256=Hash $global:transportFixture.Archive
    Reject {Run};Assert ($global:transportFixture.Invocations.Count -eq 0) 'Archive traversal reached source'
    Write-Output "PASS: $count production input transport assertions; AWS/source adapter mocked, no cloud operations."
} finally {
    foreach($path in $created){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}
    Remove-Variable transportFixture -Scope Global
    $resolved=[IO.Path]::GetFullPath($temp)
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($resolved).StartsWith('oficina-production-transport-')){throw 'Unsafe cleanup target'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
