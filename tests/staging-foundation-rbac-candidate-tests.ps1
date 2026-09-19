$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=Split-Path -Parent $PSScriptRoot
function aws{throw 'Offline test forbids AWS'}
$out=Join-Path ([IO.Path]::GetTempPath()) ('oficina-foundation-rbac-test-'+[guid]::NewGuid())
$script:checks=0
function Assert($condition,$message){if(-not$condition){throw $message};$script:checks++}
try{
    $args=@{Environment='staging';AppDeployerPrincipalArn='arn:aws:iam::638612472889:role/oficina-phase3-oficina-app-staging-deploy-role';OutputDirectory=$out}
    $path=& "$repo/scripts/render-staging-foundation-rbac.ps1" @args
    $before=(Get-FileHash $path).Hash
    $bundle=Get-Content -Raw $path|ConvertFrom-Json
    Assert ($bundle.items.Count -eq 3 -and ($bundle.items.kind -join ',') -ceq 'Namespace,Role,RoleBinding') 'Exactly three source-derived objects required'
    $ns=$bundle.items[0]
    $namespaceFile=Get-Content -Raw "$out/staging-namespace.json"|ConvertFrom-Json
    Assert ($namespaceFile.kind -ceq 'Namespace') 'Namespace-only file must be an object'
    Assert ($ns.metadata.name -ceq 'oficina-staging') 'Namespace escaped staging'
    Assert (@($ns.metadata.labels.PSObject.Properties).Count -eq 4) 'Unexpected Namespace labels'
    foreach($key in @('enforce','audit','warn')){Assert ($ns.metadata.labels."pod-security.kubernetes.io/$key" -ceq 'restricted') 'Pod Security restriction lost'}
    Assert ($ns.metadata.labels.'oficina.io/environment' -ceq 'staging' -and $ns.metadata.PSObject.Properties.Name -notcontains 'annotations') 'Unexpected Namespace identity/annotations'
    Assert ($bundle.items[1].rules.Count -eq 11 -and $bundle.items[2].subjects.Count -eq 1 -and $bundle.items[2].subjects[0].name -ceq $args.AppDeployerPrincipalArn) 'RBAC source contract changed'
    Assert ((Get-FileHash "$out/staging-release-rbac.json").Hash.ToLowerInvariant() -ceq 'c6376b4c5e4e9e65676612e0843334782806dbfb4b96963d1c14ffd75f2974ac') 'Previously reviewed RBAC bytes changed'
    $plan=Get-Content -Raw "$out/foundation-candidate-plan.json"|ConvertFrom-Json
    Assert ($plan.proposedChanges.Count -eq 3 -and $plan.persistentMutationAttempted -eq $false -and $plan.productionTouched -eq $false) 'Wrong scope or runtime claim'
    Assert ($plan.absentNamespaceDisposition -match 'blocked') 'Dry-run Namespace prerequisite omitted'
    & "$repo/scripts/render-staging-foundation-rbac.ps1" @args|Out-Null
    Assert ((Get-FileHash $path).Hash -ceq $before) 'Nondeterministic rendering'
    $rejected=$false;try{& "$repo/scripts/render-staging-foundation-rbac.ps1" -Environment production -AppDeployerPrincipalArn $args.AppDeployerPrincipalArn -OutputDirectory "$out/rejected"|Out-Null}catch{$rejected=$true};Assert $rejected 'Production accepted'
    Write-Output "PASS: $script:checks assertions; exact source Namespace labels, unchanged RBAC, deterministic three-object inventory, production rejection."
}finally{
    $resolved=[IO.Path]::GetFullPath($out)
    if(-not$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or -not[IO.Path]::GetFileName($resolved).StartsWith('oficina-foundation-rbac-test-')){throw 'Unsafe cleanup path'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
