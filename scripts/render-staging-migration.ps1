[CmdletBinding()]
param([switch]$Enabled,[ValidateSet('staging')][string]$Environment='staging',
 [Parameter(Mandatory)][string]$IdentityFile,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedIdentitySha256,
 [Parameter(Mandatory)][string]$BootstrapReviewFile,[Parameter(Mandatory)][string[]]$DatabaseCidrs,
 [Parameter(Mandatory)][string[]]$AwsHttpsCidrs,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(-not$Enabled){throw 'MIGRATION_RENDER_DISABLED'}
function Hash($path){(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
if((Hash $IdentityFile) -cne $ExpectedIdentitySha256){throw 'Migration identity digest mismatch'}
$identity=Get-Content -LiteralPath $IdentityFile -Raw|ConvertFrom-Json -NoEnumerate
if($identity -isnot [pscustomobject]){throw 'Identity must be an object'}
foreach($field in @('environment','sourceCommit','namespace','serviceAccountName','roleArn','bootstrapReviewSha256')){if($identity.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($identity.$field)){throw 'Identity scalar field missing'}}
if($identity.environment -cne 'staging' -or $identity.namespace -cne 'oficina-staging' -or $identity.serviceAccountName -cne 'oficina-migration-staging' -or
 $identity.roleArn -cnotmatch '^arn:aws:iam::([0-9]{12}):role/oficina-phase3-staging-migration$' -or (Hash $BootstrapReviewFile) -cne $identity.bootstrapReviewSha256){throw 'Identity source/environment/review mismatch'}
$account=[regex]::Match($identity.roleArn,'::([0-9]{12}):').Groups[1].Value
if($identity.schemaVersion -isnot [long] -or $identity.schemaVersion -ne 1 -or $identity.sourceCommit -cnotmatch '^[a-f0-9]{40}$' -or
 $identity.oidcIssuer -isnot [string] -or $identity.oidcIssuer -cnotmatch '^https://oidc\.eks\.us-east-1\.amazonaws\.com/id/[A-Fa-f0-9]{32}$' -or
 $identity.oidcProviderArn -isnot [string] -or $identity.oidcProviderArn -cne "arn:aws:iam::${account}:oidc-provider/$($identity.oidcIssuer.Substring(8))"){throw 'Exact source/schema/OIDC required'}
$review=Get-Content -LiteralPath $BootstrapReviewFile -Raw|ConvertFrom-Json
if($review.sourceCommit -cne $identity.sourceCommit -or $review.environment -cne 'staging' -or (@($identity.secretReferences.PSObject.Properties.Name|Sort-Object)-join ',') -cne 'app,auth,master,migration,notification'){throw 'Review source/references mismatch'}
foreach($slot in @('master','migration','app','auth','notification')){
 $expected=if($slot -ceq 'master'){$review.master}else{$review.roles.$slot};$ref=$identity.secretReferences.$slot
 if($ref.arn -isnot [string] -or $ref.versionId -isnot [string] -or $ref.arn -cne $expected.arn -or $ref.versionId -cne $expected.versionId -or $ref.arn -cnotmatch "^arn:aws:secretsmanager:us-east-1:${account}:secret:"){throw 'Bootstrap secret reference mismatch'}
 $pattern=if($slot -ceq 'master'){"^arn:aws:secretsmanager:us-east-1:${account}:secret:rds!db-[A-Za-z0-9-]+$"}else{"^arn:aws:secretsmanager:us-east-1:${account}:secret:oficina/staging/$slot-[A-Za-z0-9]{6}$"}
 if($ref.arn -cnotmatch $pattern -or $ref.versionId -cnotmatch '^[A-Za-z0-9-]{32,64}$' -or $ref.metadataSha256 -isnot [string] -or $ref.metadataSha256 -cnotmatch '^[a-f0-9]{64}$' -or $ref.kmsKeyManager -isnot [string]){throw 'Exact staging references and metadata required'}
 if($ref.kmsKeyManager -ceq 'AWS'){if($null -ne $ref.kmsKeyArn){throw 'AWS-managed key cannot add a customer grant'}}
 elseif($ref.kmsKeyManager -cne 'CUSTOMER' -or $ref.kmsKeyArn -isnot [string] -or $ref.kmsKeyArn -cnotmatch "^arn:aws:kms:us-east-1:${account}:key/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$"){throw 'Explicit KMS ownership/key required'}
}
function Peers([string[]]$cidrs){
 if($cidrs.Count -eq 0 -or @($cidrs|Select-Object -Unique).Count -ne $cidrs.Count){throw 'Explicit unique network CIDRs required'}
 foreach($cidr in $cidrs){$parts=$cidr.Split('/');$ip=$null;if($parts.Count -ne 2 -or -not[Net.IPAddress]::TryParse($parts[0],[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $parts[1] -cnotmatch '^(0|[1-9]|[12][0-9]|3[0-2])$'){throw 'Explicit IPv4 CIDR required'}}
 return (ConvertTo-Json -InputObject @($cidrs|Sort-Object|ForEach-Object {@{ipBlock=@{cidr=$_}}}) -Depth 5 -Compress)
}
if(@($DatabaseCidrs|Where-Object {$_ -match '/0$'}).Count){throw 'Database egress cannot be unrestricted'}
$repo=Split-Path -Parent $PSScriptRoot
$sa=[IO.File]::ReadAllText("$repo/k8s/platform/migration/service-account.json.tftpl").Replace('${MIGRATION_IRSA_ROLE_ARN}',$identity.roleArn)|ConvertFrom-Json
$np=[IO.File]::ReadAllText("$repo/k8s/platform/migration/network-policy.json.tftpl").Replace('${DATABASE_PEERS}',(Peers $DatabaseCidrs)).Replace('${HTTPS_PEERS}',(Peers $AwsHttpsCidrs))|ConvertFrom-Json
New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
foreach($entry in @(@{name='migration-serviceaccount.json';value=$sa},@{name='migration-network-policy.json';value=$np})){
 [IO.File]::WriteAllText((Join-Path $OutputDirectory $entry.name),($entry.value|ConvertTo-Json -Depth 25 -Compress),[Text.UTF8Encoding]::new($false))
}
Copy-Item -LiteralPath $IdentityFile -Destination (Join-Path $OutputDirectory 'migration-identity.json')
$receipt=@{status='RENDERED_ONLY';environment='staging';sourceCommit=$identity.sourceCommit;migrationIdentitySha256=$ExpectedIdentitySha256;bootstrapReviewSha256=$identity.bootstrapReviewSha256;serviceAccountSha256=(Hash (Join-Path $OutputDirectory 'migration-serviceaccount.json'));networkPolicySha256=(Hash (Join-Path $OutputDirectory 'migration-network-policy.json'));databaseCidrs=$DatabaseCidrs;awsHttpsCidrs=$AwsHttpsCidrs}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'migration-render-receipt.json'),($receipt|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
Write-Output 'RENDERED_ONLY: no AWS/Kubernetes calls or apply.'
