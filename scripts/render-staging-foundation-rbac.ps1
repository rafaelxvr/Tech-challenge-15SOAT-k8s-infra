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
$rbacPath=& "$PSScriptRoot/render-staging-deployer-rbac.ps1" -Environment staging -AppDeployerPrincipalArn $AppDeployerPrincipalArn -OutputDirectory $OutputDirectory
$rbac=Get-Content -Raw $rbacPath|ConvertFrom-Json
$rendered=& kubectl kustomize "$repo/k8s/platform/overlays/staging"
if($LASTEXITCODE -ne 0){throw 'Staging Kustomize rendering failed.'}
$documents=($rendered -join "`n") -split '(?m)^---\s*$'
$selected=@($documents|Where-Object {$_ -cmatch '(?m)^kind: Namespace\s*$' -and $_ -cmatch '(?m)^  name: oficina-staging\s*$'})
if($selected.Count -ne 1){throw 'Expected one staging Namespace.'}
$namespaceYaml=Join-Path $OutputDirectory 'staging-namespace.yaml'
[IO.File]::WriteAllText([IO.Path]::GetFullPath($namespaceYaml),($selected[0].Trim()+"`n"),[Text.UTF8Encoding]::new($false))
$namespaceDocuments=Read-PlatformManifest $namespaceYaml
$namespace=$namespaceDocuments[0]
if($namespace.kind -cne 'Namespace' -or $namespace.apiVersion -cne 'v1' -or $namespace.metadata.name -cne 'oficina-staging'){throw 'Namespace identity mismatch.'}
$labels=$namespace.metadata.labels
if(@($labels.PSObject.Properties).Count -ne 4 -or $labels.'oficina.io/environment' -cne 'staging' -or $labels.'pod-security.kubernetes.io/enforce' -cne 'restricted' -or $labels.'pod-security.kubernetes.io/audit' -cne 'restricted' -or $labels.'pod-security.kubernetes.io/warn' -cne 'restricted' -or $namespace.metadata.PSObject.Properties.Name -contains 'annotations'){throw 'Namespace source security labels/annotations changed; review required.'}
$namespacePath=Join-Path $OutputDirectory 'staging-namespace.json'
Write-OrderedPlatformJson $namespace $namespacePath
$bundlePath=Join-Path $OutputDirectory 'staging-foundation-rbac.json'
Write-OrderedPlatformJson @{apiVersion='v1';kind='List';items=@($namespace)+@($rbac.items)} $bundlePath
Write-OrderedPlatformJson @{schemaVersion=1;status='REVIEW_ONLY_NOT_A_LIVE_PLAN';environment='staging';namespace='oficina-staging';namespaceSha256=(Get-FileHash $namespacePath).Hash.ToLowerInvariant();rbacSha256=(Get-FileHash $rbacPath).Hash.ToLowerInvariant();bundleSha256=(Get-FileHash $bundlePath).Hash.ToLowerInvariant();proposedChanges=@([pscustomobject]@{kind='Namespace';name='oficina-staging';action='create-if-absent'},[pscustomobject]@{kind='Role';namespace='oficina-staging';name='oficina-release-deployer';action='create-if-absent'},[pscustomobject]@{kind='RoleBinding';namespace='oficina-staging';name='oficina-release-deployer';action='create-if-absent'});absentNamespaceDisposition='Server dry-run validates Namespace only; namespaced RBAC validation is blocked until separately approved persistent Namespace creation.';persistentMutationAttempted=$false;productionTouched=$false} (Join-Path $OutputDirectory 'foundation-candidate-plan.json')
Write-Output $bundlePath
