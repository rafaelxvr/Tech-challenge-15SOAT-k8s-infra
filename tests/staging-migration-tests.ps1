Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$temp=Join-Path ([IO.Path]::GetTempPath()) ('migration-render-'+[guid]::NewGuid())
New-Item -ItemType Directory $temp|Out-Null
$script:checks=0
function Assert([bool]$ok,[string]$why){if(-not$ok){throw $why};$script:checks++}
function Reject([scriptblock]$action){try{& $action|Out-Null}catch{$script:checks++;return};throw 'Expected render rejection'}
function Hash($path){(Get-FileHash $path).Hash.ToLowerInvariant()}
function aws {throw 'Offline test forbids AWS'}
function kubectl {throw 'Offline renderer forbids cluster calls'}
function SaveIdentity {$identity|ConvertTo-Json -Depth 20 -Compress|Set-Content "$temp/identity.json" -NoNewline;$params.ExpectedIdentitySha256=Hash "$temp/identity.json"}
try{
    $module=Get-Content "$repo/infra/modules/staging-migration-irsa/main.tf" -Raw
    $resources=@([regex]::Matches($module,'(?m)^resource "([^"]+)" "([^"]+)"')|ForEach-Object {$_.Groups[1].Value+'.'+$_.Groups[2].Value}|Sort-Object)
    Assert ($resources.Count -eq 2 -and $resources -ccontains 'aws_iam_role.migration' -and $resources -ccontains 'aws_iam_role_policy.bootstrap') 'Migration module must own exactly its dedicated role and inline policy'
    $foundation=Get-Content "$repo/infra/foundation/staging-migration-irsa.tf" -Raw
    Assert ($foundation -match 'default\s*=\s*null' -and $foundation.Contains('var.staging_migration_irsa == null ? {} : { staging = var.staging_migration_irsa }')) 'Foundation migration activation remains opt-in and staging-only'
    Assert ($module -notmatch 'module\.staging_app_irsa|aws_iam_role\.app|production') 'Migration policy must not reference APP or production identities'
    $roles=@{};$refs=@{}
    foreach($slot in @('master','migration','app','auth','notification')){
        $arn=if($slot -ceq 'master'){'arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-test'}else{"arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/$slot-AbCd12"}
        $roles[$slot]=@{arn=$arn;versionId=('1'*32)}
        $refs[$slot]=@{arn=$arn;versionId=('1'*32);kmsKeyManager='AWS';kmsKeyArn=$null;metadataSha256=('c'*64)}
    }
    $review=@{schemaVersion=1;environment='staging';sourceCommit=('a'*40);master=$roles.master;roles=@{migration=$roles.migration;app=$roles.app;auth=$roles.auth;notification=$roles.notification}}
    $review|ConvertTo-Json -Depth 20 -Compress|Set-Content "$temp/review.json" -NoNewline
    $issuer='oidc.eks.us-east-1.amazonaws.com/id/'+('A'*32)
    $identity=@{schemaVersion=1;environment='staging';sourceCommit=('a'*40);namespace='oficina-staging';serviceAccountName='oficina-migration-staging';roleArn='arn:aws:iam::123456789012:role/oficina-phase3-staging-migration';oidcIssuer="https://$issuer";oidcProviderArn="arn:aws:iam::123456789012:oidc-provider/$issuer";bootstrapReviewSha256=(Hash "$temp/review.json");secretReferences=$refs}
    $params=@{IdentityFile="$temp/identity.json";BootstrapReviewFile="$temp/review.json";DatabaseCidrs=@('10.42.64.0/24','10.42.65.0/24');AwsHttpsCidrs=@('10.42.80.0/24');OutputDirectory="$temp/rendered"}
    SaveIdentity
    Reject {& "$repo/scripts/render-staging-migration.ps1" @params}
    & "$repo/scripts/render-staging-migration.ps1" @params -Enabled|Out-Null
    $sa=Get-Content "$temp/rendered/migration-serviceaccount.json" -Raw|ConvertFrom-Json
    $np=Get-Content "$temp/rendered/migration-network-policy.json" -Raw|ConvertFrom-Json
    Assert ($sa.metadata.name -ceq 'oficina-migration-staging' -and $sa.metadata.namespace -ceq 'oficina-staging' -and $sa.automountServiceAccountToken -eq $false -and $sa.metadata.annotations.'eks.amazonaws.com/role-arn' -ceq $identity.roleArn) 'Exact distinct staging SA required'
    Assert ($np.spec.podSelector.matchLabels.'app.kubernetes.io/name' -ceq 'oficina-migration' -and ($np.spec.policyTypes -join ',') -ceq 'Egress' -and $np.spec.egress.Count -eq 3) 'Only migration egress is permitted'
    Assert (($np.spec.egress[1].to.ipBlock.cidr -join ',') -ceq '10.42.64.0/24,10.42.65.0/24' -and $np.spec.egress[1].ports[0].port -eq 5432 -and $np.spec.egress[2].ports[0].port -eq 443) 'Reviewed DB and AWS HTTPS paths required'
    Assert ($np.spec.egress[0].to.Count -eq 1 -and $np.spec.egress[0].to[0].namespaceSelector.matchLabels.'kubernetes.io/metadata.name' -ceq 'kube-system' -and $np.spec.egress[0].to[0].podSelector.matchLabels.'k8s-app' -ceq 'kube-dns') 'DNS must bind namespace AND pod selectors in the same peer'
    $first=Hash "$temp/rendered/migration-network-policy.json"
    & "$repo/scripts/render-staging-migration.ps1" @params -Enabled|Out-Null
    Assert ((Hash "$temp/rendered/migration-network-policy.json") -ceq $first) 'Rendering must be deterministic'
    $receipt=Get-Content "$temp/rendered/migration-render-receipt.json" -Raw|ConvertFrom-Json
    Assert ($receipt.networkPolicySha256 -ceq $first -and $receipt.migrationIdentitySha256 -ceq (Hash "$temp/identity.json")) 'Receipt must bind exact identity/network bytes'
    Reject {& "$repo/scripts/render-staging-migration.ps1" @params -Enabled -Environment production}
    foreach($field in @('environment','namespace','serviceAccountName','roleArn','sourceCommit')){
        $old=$identity[$field];$identity[$field]='production';SaveIdentity
        Reject {& "$repo/scripts/render-staging-migration.ps1" @params -Enabled}
        $identity[$field]=$old;SaveIdentity
    }
    $identity.secretReferences.app.kmsKeyManager='CUSTOMER';SaveIdentity
    Reject {& "$repo/scripts/render-staging-migration.ps1" @params -Enabled}
    $identity.secretReferences.app.kmsKeyManager='AWS';SaveIdentity
    $identity.oidcProviderArn='arn:aws:iam::999999999999:oidc-provider/unreviewed';SaveIdentity
    Reject {& "$repo/scripts/render-staging-migration.ps1" @params -Enabled}
    $identity.oidcProviderArn="arn:aws:iam::123456789012:oidc-provider/$issuer";SaveIdentity
    $params.ExpectedIdentitySha256='0'*64;Reject {& "$repo/scripts/render-staging-migration.ps1" @params -Enabled};SaveIdentity
    $params.DatabaseCidrs=@('0.0.0.0/0');Reject {& "$repo/scripts/render-staging-migration.ps1" @params -Enabled};$params.DatabaseCidrs=@('10.42.64.0/24')
    $params.AwsHttpsCidrs=@('unresolved');Reject {& "$repo/scripts/render-staging-migration.ps1" @params -Enabled}
    Write-Output "PASS: $script:checks staging migration renderer assertions; no cloud commands."
}finally{if(-not [IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup'};Remove-Item -LiteralPath $temp -Recurse -Force}
