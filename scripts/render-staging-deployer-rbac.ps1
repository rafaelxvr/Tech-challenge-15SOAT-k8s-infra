[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('staging')][string]$Environment,
    [Parameter(Mandatory)][ValidatePattern('^arn:aws:iam::638612472889:role/oficina-phase3-oficina-app-staging-deploy-role$')][string]$AppDeployerPrincipalArn,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($Environment -cne 'staging' -or $AppDeployerPrincipalArn -cne 'arn:aws:iam::638612472889:role/oficina-phase3-oficina-app-staging-deploy-role'){throw 'Only the reviewed staging APP identity is supported.'}
$repo=Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/platform-manifest-contract.ps1"
# Local rendering only; this command never contacts the Kubernetes API.
$rendered=& kubectl kustomize "$repo/k8s/platform/overlays/staging"
if($LASTEXITCODE -ne 0){throw 'Staging Kustomize rendering failed.'}
$documents=($rendered -join "`n") -split '(?m)^---\s*$'
$selected=@($documents | Where-Object {$_ -cmatch '(?m)^kind: (Role|RoleBinding)\s*$' -and $_ -cmatch '(?m)^  name: oficina-release-deployer\s*$'})
if($selected.Count -ne 2){throw 'Expected exactly the release Role and RoleBinding.'}
$yaml=($selected.Trim() -join "`n---`n").Replace('${DEPLOYER_PRINCIPAL_ARN}',$AppDeployerPrincipalArn)+"`n"
if($yaml -match '\$\{[^}]+\}'){throw 'Unresolved RBAC input token.'}
New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
$yamlPath=Join-Path $OutputDirectory 'staging-release-rbac.yaml'
[IO.File]::WriteAllText([IO.Path]::GetFullPath($yamlPath),$yaml,[Text.UTF8Encoding]::new($false))
$parsed=Read-PlatformManifest $yamlPath
$objects=@()
foreach($kind in @('Role','RoleBinding')){
    $matches=@($parsed|Where-Object {$_.kind -ceq $kind})
    if($matches.Count -ne 1 -or $matches[0].metadata.name -cne 'oficina-release-deployer' -or $matches[0].metadata.namespace -cne 'oficina-staging' -or $matches[0].apiVersion -cne 'rbac.authorization.k8s.io/v1'){throw 'RBAC object identity mismatch.'}
    $objects+=$matches[0]
}
$subjects=@($objects[1].subjects)
if($subjects.Count -ne 1 -or $subjects[0].kind -cne 'User' -or $subjects[0].name -cne $AppDeployerPrincipalArn -or $subjects[0].apiGroup -cne 'rbac.authorization.k8s.io' -or $objects[1].roleRef.kind -cne 'Role' -or $objects[1].roleRef.name -cne 'oficina-release-deployer'){throw 'RoleBinding subject/reference mismatch.'}
$bundle=Join-Path $OutputDirectory 'staging-release-rbac.json'
Write-OrderedPlatformJson @{apiVersion='v1';kind='List';items=$objects} $bundle
$plan=@{schemaVersion=1;status='REVIEW_ONLY_NOT_A_LIVE_PLAN';environment='staging';namespace='oficina-staging';bundleSha256=(Get-FileHash $bundle).Hash.ToLowerInvariant();appPrincipalArn=$AppDeployerPrincipalArn;changes=@($objects|ForEach-Object {[pscustomobject]@{action='create';apiVersion=$_.apiVersion;kind=$_.kind;name=$_.metadata.name;namespace=$_.metadata.namespace}});prerequisites=@('Live namespace existence and Active phase must be verified from the private executor.','Both objects must still be absent; stop on drift.','Server dry-run/admission checks must pass before any separately approved create.');cloudExecuted=$false}
Write-OrderedPlatformJson $plan (Join-Path $OutputDirectory 'candidate-plan.json')
Write-Output $bundle
