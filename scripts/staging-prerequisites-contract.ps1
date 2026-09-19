Set-StrictMode -Version Latest
function Get-PrerequisiteHash([string]$Text){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()}
function Get-PrerequisiteCanonical($Value){
    if($null -eq $Value){return $null}
    if($Value -is [string] -or $Value.GetType().IsValueType){return $Value}
    if($Value -is [array]){return ,@($Value|ForEach-Object {Get-PrerequisiteCanonical $_})}
    $result=[ordered]@{};$names=[string[]]@($Value.PSObject.Properties|ForEach-Object Name);[Array]::Sort($names,[StringComparer]::Ordinal)
    foreach($name in $names){$result[$name]=Get-PrerequisiteCanonical $Value.$name};return $result
}
function Get-PrerequisiteObjectHash($Object){Get-PrerequisiteHash ((Get-PrerequisiteCanonical $Object)|ConvertTo-Json -Depth 70 -Compress)}
function Read-StagingPrerequisites([string]$Json,[string]$ExpectedSha256,[string]$AppSourceCommit){
    if($ExpectedSha256 -cnotmatch '^[a-f0-9]{64}$' -or (Get-PrerequisiteHash $Json) -cne $ExpectedSha256){throw 'PREREQUISITES_HASH_MISMATCH'}
    $bundle=ConvertFrom-Json -InputObject $Json -NoEnumerate
    if($bundle -isnot [pscustomobject] -or $bundle.schemaVersion -isnot [long] -or $bundle.schemaVersion -ne 1){throw 'PREREQUISITES_SCHEMA_INVALID'}
    foreach($field in @('environment','appSourceCommit','k8sSourceCommit','targetGroupArn','terraformOutputsJson','terraformOutputsSha256','terraformOutputsBucket','terraformOutputsKey','terraformOutputsVersionId')){if($bundle.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($bundle.$field)){throw 'PREREQUISITES_SCALAR_REQUIRED'}}
    if($bundle.environment -cne 'staging' -or $bundle.appSourceCommit -cne $AppSourceCommit -or $AppSourceCommit -cnotmatch '^[a-f0-9]{40}$' -or $bundle.k8sSourceCommit -cnotmatch '^[a-f0-9]{40}$' -or
       $bundle.targetGroupArn -cnotmatch '^arn:aws:elasticloadbalancing:us-east-1:[0-9]{12}:targetgroup/oficina-phase3-staging-app/[a-f0-9]{16}$' -or
       $bundle.terraformOutputsBucket -cnotmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' -or $bundle.terraformOutputsKey -cne "releases/k8s/staging/outputs/$($bundle.k8sSourceCommit).json" -or $bundle.terraformOutputsVersionId -ceq 'null' -or
       $bundle.terraformOutputsSha256 -cnotmatch '^[a-f0-9]{64}$' -or (Get-PrerequisiteHash $bundle.terraformOutputsJson) -cne $bundle.terraformOutputsSha256){throw 'PREREQUISITES_SOURCE_OUTPUT_MISMATCH'}
    $outputs=ConvertFrom-Json -InputObject $bundle.terraformOutputsJson -NoEnumerate
    if($outputs -isnot [pscustomobject] -or $outputs.environment.value -isnot [string] -or $outputs.environment.value -cne 'staging' -or $outputs.target_group_arn.value -isnot [string] -or $outputs.target_group_arn.value -cne $bundle.targetGroupArn -or $outputs.namespace.value -isnot [string] -or $outputs.namespace.value -cne 'oficina-staging'){throw 'PREREQUISITES_TERRAFORM_OUTPUT_MISMATCH'}
    $expected=@('ConfigMap/oficina-runtime-public-staging','NetworkPolicy/default-deny-ingress-egress','NetworkPolicy/oficina-app-allow-required-paths','NetworkPolicy/oficina-migration-allow-required-paths','SecretProviderClass/oficina-runtime-secrets','Service/oficina-app','ServiceAccount/oficina-migration-staging','TargetGroupBinding/oficina-app')
    if($bundle.objects -isnot [array] -or $bundle.objects.Count -ne 8){throw 'PREREQUISITES_EXACT_OBJECTS_REQUIRED'}
    $ids=@();foreach($object in $bundle.objects){
        foreach($value in @($object.kind,$object.apiVersion,$object.metadata.name,$object.metadata.namespace)){if($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)){throw 'PREREQUISITES_OBJECT_IDENTITY_INVALID'}}
        $api=@{ConfigMap='v1';Service='v1';ServiceAccount='v1';SecretProviderClass='secrets-store.csi.x-k8s.io/v1';TargetGroupBinding='elbv2.k8s.aws/v1beta1';NetworkPolicy='networking.k8s.io/v1'}[$object.kind]
        if($object.metadata.namespace -cne 'oficina-staging' -or $object.apiVersion -cne $api -or (($object|ConvertTo-Json -Depth 70 -Compress) -match '\$\{')){throw 'PREREQUISITES_OBJECT_SCOPE_INVALID'}
        $ids+="$($object.kind)/$($object.metadata.name)"
    }
    if((@($ids|Sort-Object)-join ',') -cne ($expected-join ',')){throw 'PREREQUISITES_OBJECT_SET_INVALID'}
    $account=$bundle.targetGroupArn.Split(':')[4]
    $serialized=$bundle.objects|ConvertTo-Json -Depth 70 -Compress
    if($serialized -match 'oficina(?:/|-)(?:phase3-)?production|/production/'){throw 'PREREQUISITES_PRODUCTION_REFERENCE_FORBIDDEN'}
    foreach($match in [regex]::Matches($serialized,'arn:aws:[^"\s\\]+')){if($match.Value -cnotmatch "^arn:aws:[^:]+:(us-east-1)?:${account}:"){throw 'PREREQUISITES_FOREIGN_AWS_REFERENCE'}}
    $service=@($bundle.objects|Where-Object kind -CEQ 'Service')[0]
    if($service.spec.type -isnot [string] -or $service.spec.type -cne 'ClusterIP' -or $service.spec.selector.'app.kubernetes.io/name' -isnot [string] -or $service.spec.selector.'app.kubernetes.io/name' -cne 'oficina-app'){throw 'PREREQUISITES_INTERNAL_SERVICE_REQUIRED'}
    $sa=@($bundle.objects|Where-Object kind -CEQ 'ServiceAccount')[0]
    if($sa.automountServiceAccountToken -isnot [bool] -or $sa.automountServiceAccountToken -or $sa.metadata.annotations.'eks.amazonaws.com/role-arn' -isnot [string] -or $sa.metadata.annotations.'eks.amazonaws.com/role-arn' -cne "arn:aws:iam::${account}:role/oficina-phase3-staging-migration"){throw 'PREREQUISITES_MIGRATION_IDENTITY_REQUIRED'}
    $binding=@($bundle.objects|Where-Object kind -CEQ 'TargetGroupBinding')[0]
    if($binding.spec.targetGroupARN -isnot [string] -or $binding.spec.targetGroupARN -cne $bundle.targetGroupArn -or $binding.spec.targetType -isnot [string] -or $binding.spec.targetType -cne 'ip' -or $binding.spec.serviceRef.name -isnot [string] -or $binding.spec.serviceRef.port -isnot [long] -or $binding.spec.serviceRef.name -cne 'oficina-app' -or $binding.spec.serviceRef.port -ne 8080){throw 'PREREQUISITES_TARGET_BINDING_INVALID'}
    return $bundle
}
function Assert-PrerequisiteReadback($Actual,$Expected){
    foreach($field in @('kind','apiVersion')){if($Actual.$field -isnot [string]){throw 'PREREQUISITES_READBACK_SCALAR_REQUIRED'}}
    foreach($field in @('name','namespace')){if($Actual.metadata.$field -isnot [string]){throw 'PREREQUISITES_READBACK_SCALAR_REQUIRED'}}
    if($Actual -isnot [pscustomobject] -or $Actual.kind -cne $Expected.kind -or $Actual.apiVersion -cne $Expected.apiVersion -or $Actual.metadata.name -cne $Expected.metadata.name -or $Actual.metadata.namespace -cne 'oficina-staging'){throw 'PREREQUISITES_READBACK_IDENTITY_MISMATCH'}
    foreach($field in @('uid','resourceVersion')){if($Actual.metadata.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($Actual.metadata.$field)){throw 'PREREQUISITES_READBACK_METADATA_REQUIRED'}}
    foreach($field in @('labels','annotations')){if($null -ne $Expected.metadata.PSObject.Properties[$field]){foreach($p in $Expected.metadata.$field.PSObject.Properties){if($Actual.metadata.$field.($p.Name) -isnot [string] -or $Actual.metadata.$field.($p.Name) -cne $p.Value){throw 'PREREQUISITES_METADATA_DRIFT'}}}}
    foreach($field in @('spec','data','automountServiceAccountToken')){
        if($null -eq $Expected.PSObject.Properties[$field]){continue}
        $value=$Actual.$field
        if($field -ceq 'spec' -and $Expected.kind -ceq 'Service'){
            $value=$value|ConvertTo-Json -Depth 30|ConvertFrom-Json
            foreach($default in @(@{name='sessionAffinity';value='None'},@{name='internalTrafficPolicy';value='Cluster'})){if($null -eq $Expected.spec.PSObject.Properties[$default.name] -and $null -ne $value.PSObject.Properties[$default.name] -and $value.($default.name) -cne $default.value){throw 'PREREQUISITES_SERVICE_DEFAULT_DRIFT'}}
            for($i=0;$i -lt $value.ports.Count;$i++){if($i -ge $Expected.spec.ports.Count){throw 'PREREQUISITES_SERVICE_PORT_DRIFT'};if($null -eq $Expected.spec.ports[$i].PSObject.Properties['protocol'] -and $null -ne $value.ports[$i].PSObject.Properties['protocol']){if($value.ports[$i].protocol -cne 'TCP'){throw 'PREREQUISITES_SERVICE_PROTOCOL_DRIFT'};$value.ports[$i].PSObject.Properties.Remove('protocol')}}
            foreach($default in @('clusterIP','clusterIPs','ipFamilies','ipFamilyPolicy','internalTrafficPolicy','sessionAffinity')){if($null -eq $Expected.spec.PSObject.Properties[$default]){$value.PSObject.Properties.Remove($default)}}
        }
        if((Get-PrerequisiteObjectHash $value) -cne (Get-PrerequisiteObjectHash $Expected.$field)){throw 'PREREQUISITES_SPEC_DRIFT'}
    }
}
function Assert-PrerequisiteReceipt($Receipt,$Bundle,[string]$BundleSha){
    foreach($field in @('status','environment','appSourceCommit','k8sSourceCommit','bundleSha256')){if($Receipt.$field -isnot [string]){throw 'PREREQUISITES_RECEIPT_SCALAR_REQUIRED'}}
    if($Receipt -isnot [pscustomobject] -or $Receipt.status -isnot [string] -or $Receipt.status -cnotin @('CREATED_VERIFIED','EXISTING_VERIFIED') -or $Receipt.environment -cne 'staging' -or $Receipt.appSourceCommit -cne $Bundle.appSourceCommit -or $Receipt.k8sSourceCommit -cne $Bundle.k8sSourceCommit -or $Receipt.bundleSha256 -cne $BundleSha -or $Receipt.objects -isnot [array] -or $Receipt.objects.Count -ne 8){throw 'PREREQUISITES_VERIFIED_RECEIPT_REQUIRED'}
    foreach($expected in $Bundle.objects){$objects=@($Receipt.objects|Where-Object {$_.kind -ceq $expected.kind -and $_.metadata.name -ceq $expected.metadata.name});if($objects.Count -ne 1){throw 'PREREQUISITES_RECEIPT_OBJECT_MISSING'};Assert-PrerequisiteReadback $objects[0] $expected}
}
