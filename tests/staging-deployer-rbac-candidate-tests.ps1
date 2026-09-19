$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=Split-Path -Parent $PSScriptRoot
function aws {throw 'Offline test prohibits AWS.'}
$out=Join-Path ([IO.Path]::GetTempPath()) ('oficina-rbac-candidate-test-'+[guid]::NewGuid())
$role='arn:aws:iam::638612472889:role/oficina-phase3-oficina-app-staging-deploy-role'
$checks=0
function Assert($condition,$message){if(-not $condition){throw $message};$script:checks++}
try{
    $parameters=@{Environment='staging';AppDeployerPrincipalArn=$role;OutputDirectory=$out}
    $path=& "$repo/scripts/render-staging-deployer-rbac.ps1" @parameters
    $hash=(Get-FileHash $path).Hash
    $list=Get-Content -Raw $path|ConvertFrom-Json
    Assert ($list.items.Count -eq 2 -and ($list.items.kind -join ',') -ceq 'Role,RoleBinding') 'Exactly two ordered RBAC objects required.'
    foreach($item in $list.items){Assert ($item.metadata.namespace -ceq 'oficina-staging' -and $item.metadata.name -ceq 'oficina-release-deployer') 'Object escaped staging.'}
    Assert ($list.items[0].rules.Count -eq 11) 'Source staging 6+5 rule contract changed.'
    Assert ($list.items[1].subjects.Count -eq 1 -and $list.items[1].subjects[0].name -ceq $role -and $list.items[1].subjects[0].kind -ceq 'User') 'APP IAM ARN User binding changed.'
    Assert (@($list.items[0].rules|Where-Object {$_.resources -contains 'roles' -or $_.resources -contains 'rolebindings' -or $_.verbs -contains 'bind' -or $_.verbs -contains 'escalate'}).Count -eq 0) 'APP must not gain RBAC inspection/mutation.'
    $plan=Get-Content -Raw "$out/candidate-plan.json"|ConvertFrom-Json
    Assert ($plan.status -ceq 'REVIEW_ONLY_NOT_A_LIVE_PLAN' -and $plan.changes.Count -eq 2 -and ($plan.changes.action -join ',') -ceq 'create,create' -and $plan.cloudExecuted -eq $false) 'Plan misrepresents live evidence or actions.'
    Assert ($plan.bundleSha256 -ceq $hash.ToLowerInvariant()) 'Plan digest mismatch.'
    & "$repo/scripts/render-staging-deployer-rbac.ps1" @parameters|Out-Null
    Assert ((Get-FileHash $path).Hash -ceq $hash) 'Rendering not deterministic.'
    foreach($bad in @(@{Environment='production';AppDeployerPrincipalArn=$role},@{Environment='staging';AppDeployerPrincipalArn=$role.Replace('staging','production')},@{Environment='staging';AppDeployerPrincipalArn=$role.Replace('638612472889','111111111111')})){
        $rejected=$false;try{& "$repo/scripts/render-staging-deployer-rbac.ps1" @bad -OutputDirectory "$out/rejected"|Out-Null}catch{$rejected=$true};Assert $rejected 'Invalid production/account input accepted.'
    }
    Assert (-not(Test-Path "$out/rejected")) 'Rejected render wrote artifacts.'
    Write-Output "PASS: $checks assertions; deterministic two-object candidate; production/account rejection; no cloud calls."
}finally{
    $resolved=[IO.Path]::GetFullPath($out)
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($resolved).StartsWith('oficina-rbac-candidate-test-')){throw 'Unsafe cleanup path'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
