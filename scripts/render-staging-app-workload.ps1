[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('staging')][string]$Environment,
    [Parameter(Mandatory)][string]$PlatformManifestFile,
    [Parameter(Mandatory)][ValidatePattern('\A[a-f0-9]{64}\z')][string]$ExpectedPlatformSha256,
    [Parameter(Mandatory)][string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'platform-manifest-contract.ps1')
if($Environment -cne 'staging'){throw 'APP bootstrap rendering is staging-only.'}
$actual=(Get-FileHash -LiteralPath $PlatformManifestFile -Algorithm SHA256).Hash.ToLowerInvariant()
if($actual -cne $ExpectedPlatformSha256){throw 'Reviewed platform manifest digest mismatch.'}
$documents=Read-PlatformManifest $PlatformManifestFile
$objects=@()
foreach($kind in @('Deployment','ServiceAccount','HorizontalPodAutoscaler')) {
    $selected=@($documents | Where-Object {$_.kind -ceq $kind -and $_.metadata.name -ceq 'oficina-app'})
    if($selected.Count -ne 1 -or $selected[0].metadata.namespace -isnot [string] -or $selected[0].metadata.namespace -cne 'oficina-staging'){
        throw 'Expected exactly one staging APP Deployment, ServiceAccount and HPA.'
    }
    $objects += $selected[0]
}
$deployment=$objects[0]; $account=$objects[1]; $hpa=$objects[2]
$containers=@($deployment.spec.template.spec.containers)
if($containers.Count -ne 1 -or $containers[0].name -cne 'app' -or $containers[0].image -isnot [string] -or
    $containers[0].image -cnotmatch '\A([0-9]{12})\.dkr\.ecr\.us-east-1\.amazonaws\.com/[a-z0-9][a-z0-9/_.-]*@sha256:[a-f0-9]{64}\z'){
    throw 'APP workload requires exactly one digest-pinned application container.'
}
$accountId=$Matches[1]
$irsa=$account.metadata.annotations.'eks.amazonaws.com/role-arn'
if($irsa -isnot [string] -or $irsa -cnotmatch "\Aarn:aws:iam::${accountId}:role/[A-Za-z0-9/+=,.@_-]+\z" -or $irsa -cnotmatch '[-/]staging(-|\z)' -or
    $deployment.spec.template.spec.serviceAccountName -cne 'oficina-app') { throw 'APP IRSA must bind the same-account staging identity.' }
if($hpa.spec.minReplicas -ne 1 -or $hpa.spec.maxReplicas -ne 2 -or $hpa.spec.scaleTargetRef.kind -cne 'Deployment' -or $hpa.spec.scaleTargetRef.name -cne 'oficina-app'){
    throw 'APP HPA must retain the staging capacity contract.'
}
# The bundle is consumed by the APP adapter; never apply this List directly.
# APP creates SA/Deployment first and restores the HPA only after migration/rollout.
$deployment.spec.replicas=0
$deployment.spec.strategy=[pscustomobject]@{type='Recreate'}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$bundlePath=Join-Path $OutputDirectory 'app-workload-staging.json'
Write-OrderedPlatformJson @{apiVersion='v1';kind='List';items=$objects} $bundlePath
$digest=(Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash.ToLowerInvariant()
$receipt=@{schemaVersion=1;environment='staging';platformManifestSha256=$actual;stagingWorkloadSha256=$digest;image=$containers[0].image;appIrsaRoleArn=$irsa;status='RENDERED_ONLY'}
Write-OrderedPlatformJson $receipt (Join-Path $OutputDirectory 'app-workload-staging.receipt.json')
Write-Output $bundlePath
