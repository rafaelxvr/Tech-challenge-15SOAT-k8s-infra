[CmdletBinding()]
param([Parameter(Mandatory)][string]$PlatformManifestFile,[Parameter(Mandatory)][string]$ExpectedPlatformSha256,
[Parameter(Mandatory)][string]$MigrationDirectory,[Parameter(Mandatory)][string]$RuntimePublicConfigMapFile,[Parameter(Mandatory)][string]$ExpectedPublicSha256,
[Parameter(Mandatory)][string]$TerraformOutputsFile,[Parameter(Mandatory)][string]$ExpectedTerraformOutputsSha256,[Parameter(Mandatory)][string]$TerraformOutputsBucket,[Parameter(Mandatory)][string]$TerraformOutputsKey,[Parameter(Mandatory)][string]$TerraformOutputsVersionId,
[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$AppSourceCommit,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$K8sSourceCommit,[Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
. "$PSScriptRoot/platform-manifest-contract.ps1"
. "$PSScriptRoot/staging-prerequisites-contract.ps1"
function RequireHash($Path,$Sha){if($Sha -isnot [string] -or $Sha -cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() -cne $Sha){throw 'PREREQUISITES_RENDER_INPUT_HASH_MISMATCH'}}
RequireHash $PlatformManifestFile $ExpectedPlatformSha256;RequireHash $RuntimePublicConfigMapFile $ExpectedPublicSha256;RequireHash $TerraformOutputsFile $ExpectedTerraformOutputsSha256
$outputsJson=[IO.File]::ReadAllText($TerraformOutputsFile);$outputs=$outputsJson|ConvertFrom-Json
if($outputs.environment.value -cne 'staging'){throw 'Staging outputs required'}
$documents=Read-PlatformManifest $PlatformManifestFile
$objects=@();foreach($id in @('Service/oficina-app','NetworkPolicy/default-deny-ingress-egress','NetworkPolicy/oficina-app-allow-required-paths','SecretProviderClass/oficina-runtime-secrets')){$kind,$name=$id.Split('/');$selected=@($documents|Where-Object {$_.kind -ceq $kind -and $_.metadata.name -ceq $name});if($selected.Count -ne 1){throw 'Missing source platform object'};$objects+=$selected[0]}
$migrationReceipt=Get-Content -LiteralPath "$MigrationDirectory/migration-render-receipt.json" -Raw|ConvertFrom-Json
if($migrationReceipt.environment -cne 'staging' -or $migrationReceipt.sourceCommit -cne $AppSourceCommit -or $migrationReceipt.status -cne 'RENDERED_ONLY'){throw 'Migration source mismatch'}
RequireHash "$MigrationDirectory/migration-serviceaccount.json" $migrationReceipt.serviceAccountSha256
RequireHash "$MigrationDirectory/migration-network-policy.json" $migrationReceipt.networkPolicySha256
$objects+=Get-Content -LiteralPath "$MigrationDirectory/migration-serviceaccount.json" -Raw|ConvertFrom-Json
$objects+=Get-Content -LiteralPath "$MigrationDirectory/migration-network-policy.json" -Raw|ConvertFrom-Json
$objects+=Get-Content -LiteralPath $RuntimePublicConfigMapFile -Raw|ConvertFrom-Json
New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
$bindingPath=& "$PSScriptRoot/render-target-group-binding.ps1" -Environment staging -TargetGroupArn $outputs.target_group_arn.value -OutputDirectory $OutputDirectory
$binding=Read-PlatformManifest $bindingPath;$objects+=$binding[0]
$bundle=@{schemaVersion=1;environment='staging';appSourceCommit=$AppSourceCommit;k8sSourceCommit=$K8sSourceCommit;targetGroupArn=$outputs.target_group_arn.value;terraformOutputsJson=$outputsJson;terraformOutputsSha256=$ExpectedTerraformOutputsSha256;terraformOutputsBucket=$TerraformOutputsBucket;terraformOutputsKey=$TerraformOutputsKey;terraformOutputsVersionId=$TerraformOutputsVersionId;migrationNetworkPolicySha256=$migrationReceipt.networkPolicySha256;runtimePublicConfigMapSha256=$ExpectedPublicSha256;objects=@($objects|Sort-Object kind,{ $_.metadata.name })}
$path=Join-Path $OutputDirectory 'staging-prerequisites.json';Write-OrderedPlatformJson $bundle $path
$sha=(Get-FileHash $path).Hash.ToLowerInvariant();$null=Read-StagingPrerequisites ([IO.File]::ReadAllText($path)) $sha $AppSourceCommit
Write-OrderedPlatformJson @{status='RENDERED_ONLY';bundleSha256=$sha;platformManifestSha256=$ExpectedPlatformSha256;runtimePublicConfigMapSha256=$ExpectedPublicSha256;terraformOutputsSha256=$ExpectedTerraformOutputsSha256;migrationIdentitySha256=$migrationReceipt.migrationIdentitySha256;migrationNetworkPolicySha256=$migrationReceipt.networkPolicySha256} (Join-Path $OutputDirectory 'staging-prerequisites.receipt.json')
Write-Output $path
