[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$temp=Join-Path ([IO.Path]::GetTempPath()) ('oficina-staging-bundle-test-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
$script:checks=0
function Assert([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message}; $script:checks++ }
function Reject([scriptblock]$Action) { try { & $Action | Out-Null } catch { $script:checks++; return }; throw 'Expected rejection.' }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function aws { throw 'Offline contract forbids AWS.' }
function Assert-RuntimeIdentity([object]$Pod) {
    foreach($entry in $Pod.containers[0].env) {
        if($null -ne $entry.PSObject.Properties['value']) {
            Assert ($entry.value -is [string]) "Kubernetes env value must remain a string: $($entry.name)."
        }
    }
    $account=@($Pod.containers[0].env | Where-Object name -CEQ 'NEW_RELIC_ACCOUNT_ID')
    Assert ($account.Count -eq 1 -and $account[0].value -ceq '1234567') 'New Relic account ID must preserve the reviewed string value.'
    $endpoint=@($Pod.containers[0].env | Where-Object name -CEQ 'NEW_RELIC_EVENT_ENDPOINT')
    Assert ($endpoint[0].value -ceq 'https://insights-collector.newrelic.com/v1/accounts/1234567/events') 'Quoting the account scalar must not introduce quotes inside its endpoint URL.'
    Assert ($Pod.securityContext.runAsUser -eq 10001 -and $Pod.securityContext.runAsGroup -eq 10001 -and $Pod.securityContext.fsGroup -eq 10001) 'Pod UID, primary GID and mounted-volume group must match the APP image identity 10001.'
    Assert ($Pod.securityContext.runAsNonRoot -eq $true -and $Pod.securityContext.seccompProfile.type -ceq 'RuntimeDefault') 'Explicit identity must preserve nonroot and runtime-default seccomp.'
    $container=$Pod.containers[0].securityContext
    Assert ($container.allowPrivilegeEscalation -eq $false -and $container.readOnlyRootFilesystem -eq $true -and ($container.capabilities.drop -join ',') -ceq 'ALL') 'Container must retain privilege, filesystem and capability restrictions.'
    Assert ($null -eq $container.PSObject.Properties['runAsUser'] -and $null -eq $container.PSObject.Properties['runAsGroup']) 'Container must inherit the reviewed pod UID/GID without overrides.'
}
try {
    $staging=& kubectl kustomize "$repo/k8s/platform/overlays/staging"
    if($LASTEXITCODE -ne 0){throw 'kustomize failed.'}
    Assert (($staging -join "`n") -match '(?m)^  -? serviceaccounts$|(?m)^  - serviceaccounts$') 'Staging must grant the reviewed service-account operations.'
    . "$repo/scripts/platform-manifest-contract.ps1"
    foreach($environment in @('staging','production')) {
        $inputs=@{Environment=$environment;Image=('123456789012.dkr.ecr.us-east-1.amazonaws.com/oficina-app@sha256:'+('a'*64));AppIrsaRoleArn="arn:aws:iam::123456789012:role/oficina-app-$environment";DeployerPrincipalArn='arn:aws:iam::123456789012:role/oficina-app-deploy';PlatformBindingPrincipalArn='arn:aws:iam::123456789012:role/oficina-platform-binding';DbHost='db.oficina.internal';DbCidr='10.20.0.0/24';AlbSubnetCidrOne='10.42.0.0/24';AlbSubnetCidrTwo='10.42.1.0/24';AppSecretArn="arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/$environment/app-AbCdEf";AuthorizerTrustSecretArn="arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/$environment/authorizer-trust-AbCdEf";NewRelicIngestSecretArn="arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/$environment/newrelic-ingest-AbCdEf";NewRelicAccountId='1234567';OutputDirectory=$temp}
        $path=& "$repo/scripts/render-platform.ps1" @inputs
        $documents=Read-PlatformManifest $path
        $workload=@($documents | Where-Object kind -CEQ 'Deployment')[0]
        Assert-RuntimeIdentity $workload.spec.template.spec
        $role=@($documents | Where-Object {$_.kind -ceq 'Role' -and $_.metadata.name -ceq 'oficina-release-deployer'})[0]
        $extras=@($role.rules | Where-Object { $_.resources -contains 'serviceaccounts' -or $_.resources -contains 'jobs' -or $_.resources -contains 'pods/log' -or $_.verbs -contains 'delete' })
        if($environment -ceq 'production') {
            Assert ($role.rules.Count -eq 6) 'Production must keep the existing six Role rules.'
            Assert ($extras.Count -eq 0) 'Production must not gain staging bootstrap or HPA delete permissions.'
            $deployment=@($documents | Where-Object kind -CEQ 'Deployment')[0]
            Assert ($deployment.spec.replicas -eq 2) 'Production replica count must remain unchanged.'
            Reject { & "$repo/scripts/render-staging-app-workload.ps1" -Environment production -PlatformManifestFile $path -ExpectedPlatformSha256 (Hash $path) -OutputDirectory "$temp/rejected" }
            Reject { & "$repo/scripts/render-staging-app-workload.ps1" -Environment staging -PlatformManifestFile $path -ExpectedPlatformSha256 (Hash $path) -OutputDirectory "$temp/rejected" }
            continue
        }
        Assert ($extras.Count -eq 5 -and $role.rules.Count -eq 11) 'Staging must add exactly five least-privilege rules.'
        $configmaps=@($role.rules | Where-Object {$_.resources -contains 'configmaps'})[0]
        Assert (($configmaps.verbs -join ',') -ceq 'get,list,watch,create,patch,update' -and ($configmaps.resources -contains 'configmaps') -and ($configmaps.verbs -notcontains 'delete') -and ($configmaps.apiGroups -join ',') -ceq '') 'Bootstrap receipt ConfigMap access must remain namespaced and exclude deletion.'
        $pods=@($role.rules | Where-Object {$_.resources -contains 'pods' -and $_.resources -notcontains 'pods/log'})[0]
        Assert (($pods.verbs -join ',') -ceq 'get,list,watch' -and ($pods.resources -join ',') -ceq 'pods' -and ($pods.apiGroups -join ',') -ceq '') 'Pod status reads must remain namespaced and read-only.'
        $sa=@($extras | Where-Object {$_.resources -contains 'serviceaccounts'})
        $get=@($sa | Where-Object {$_.verbs -contains 'get'})[0]
        $create=@($sa | Where-Object {$_.verbs -contains 'create'})[0]
        Assert (($get.verbs -join ',') -ceq 'get' -and ($get.resources -join ',') -ceq 'serviceaccounts' -and ($get.resourceNames -join ',') -ceq 'oficina-app' -and ($get.apiGroups -join ',') -ceq '') 'SA read must target only oficina-app.'
        Assert (($create.verbs -join ',') -ceq 'create' -and ($create.resources -join ',') -ceq 'serviceaccounts' -and ($create.apiGroups -join ',') -ceq '' -and $null -eq $create.PSObject.Properties['resourceNames']) 'SA create must not add mutation or read permissions.'
        $jobs=@($extras | Where-Object {$_.resources -contains 'jobs'})[0]
        Assert (($jobs.verbs -join ',') -ceq 'get,list,watch,create' -and ($jobs.resources -join ',') -ceq 'jobs' -and ($jobs.apiGroups -join ',') -ceq 'batch') 'Job verbs must match get/wait/create only.'
        $logs=@($extras | Where-Object {$_.resources -contains 'pods/log'})[0]
        Assert (($logs.verbs -join ',') -ceq 'get' -and ($logs.resources -join ',') -ceq 'pods/log' -and ($logs.apiGroups -join ',') -ceq '' -and $null -eq $logs.PSObject.Properties['resourceNames']) 'Migration log reads must target only the namespaced pod log subresource.'
        $delete=@($extras | Where-Object {$_.verbs -contains 'delete'})[0]
        Assert (($delete.verbs -join ',') -ceq 'delete' -and ($delete.resources -join ',') -ceq 'horizontalpodautoscalers' -and ($delete.resourceNames -join ',') -ceq 'oficina-app' -and ($delete.apiGroups -join ',') -ceq 'autoscaling') 'HPA delete must target only the APP autoscaler.'
        Assert ($role.metadata.namespace -ceq 'oficina-staging') 'Additional permissions must stay namespaced to staging.'
        $script:stagingPath=$path
    }
    $parameters=@{Environment='staging';PlatformManifestFile=$stagingPath;ExpectedPlatformSha256=(Hash $stagingPath);OutputDirectory="$temp/bundle"}
    & "$repo/scripts/render-staging-app-workload.ps1" @parameters | Out-Null
    $bundlePath="$temp/bundle/app-workload-staging.json"
    $receiptPath="$temp/bundle/app-workload-staging.receipt.json"
    $firstHash=Hash $bundlePath; $firstReceipt=Hash $receiptPath
    $bundle=Get-Content $bundlePath -Raw | ConvertFrom-Json
    Assert ($bundle.kind -ceq 'List' -and $bundle.items.Count -eq 3) 'APP bundle must contain only the three reviewed resources.'
    Assert (($bundle.items.kind -join ',') -ceq 'Deployment,ServiceAccount,HorizontalPodAutoscaler') 'Resource order must be deterministic.'
    $deployment=$bundle.items[0]; $pod=$deployment.spec.template.spec
    Assert-RuntimeIdentity $pod
    Assert ($deployment.spec.replicas -eq 0 -and $deployment.spec.strategy.type -ceq 'Recreate') 'Bundle must not start writers before migration.'
    Assert ($pod.containers[0].image -cmatch '@sha256:[a-f0-9]{64}$' -and $pod.containers[0].resources.requests.memory -ceq '768Mi') 'Digest and platform capacity must be retained.'
    Assert ($pod.containers[0].readinessProbe.httpGet.path -ceq '/api/actuator/health/readiness' -and $pod.volumes.Count -eq 3) 'Platform probes and volumes must survive rendering.'
    Assert ($bundle.items[1].metadata.annotations.'eks.amazonaws.com/role-arn' -ceq 'arn:aws:iam::123456789012:role/oficina-app-staging') 'IRSA binding must survive rendering.'
    Assert ($bundle.items[2].spec.minReplicas -eq 1 -and $bundle.items[2].spec.maxReplicas -eq 2) 'HPA keeps staging capacity; APP applies it only after rollout.'
    $receipt=Get-Content $receiptPath -Raw | ConvertFrom-Json
    Assert ($receipt.stagingWorkloadSha256 -ceq $firstHash -and $receipt.platformManifestSha256 -ceq (Hash $stagingPath) -and $receipt.environment -ceq 'staging') 'Receipt must bind the exact source and output bytes.'
    & "$repo/scripts/render-staging-app-workload.ps1" @parameters | Out-Null
    Assert ((Hash $bundlePath) -ceq $firstHash -and (Hash $receiptPath) -ceq $firstReceipt) 'Repeated render must be byte-identical, including receipt.'
    Reject { & "$repo/scripts/render-staging-app-workload.ps1" -Environment staging -PlatformManifestFile $stagingPath -ExpectedPlatformSha256 ('0'*64) -OutputDirectory "$temp/rejected" }
    foreach($token in @('${UNRESOLVED}','${unknown_123}')) {
        $bad=Join-Path $temp 'unresolved.yaml'; [IO.File]::WriteAllText($bad,([IO.File]::ReadAllText($stagingPath)+"`n# $token`n"))
        Reject { & "$repo/scripts/render-staging-app-workload.ps1" -Environment staging -PlatformManifestFile $bad -ExpectedPlatformSha256 (Hash $bad) -OutputDirectory "$temp/rejected" }
    }
    Assert (-not (Test-Path "$temp/rejected/app-workload-staging.json")) 'Rejected renders must produce no bundle.'
    Write-Output "PASS: $script:checks staging RBAC/workload-bundle assertions; local kustomize/Terraform console only."
} finally {
    $resolved=[IO.Path]::GetFullPath($temp)
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($resolved).StartsWith('oficina-staging-bundle-test-')){throw 'Unsafe cleanup target.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
