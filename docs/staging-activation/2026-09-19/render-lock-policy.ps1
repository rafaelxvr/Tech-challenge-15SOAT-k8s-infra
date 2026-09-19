[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$module=Join-Path $root 'infra/modules/deployment-executor'
$current=Get-Content -Raw "$PSScriptRoot/lock-policy-before.json" | ConvertFrom-Json -AsHashtable
if($current.RoleName -cne 'oficina-phase3-oficina-app-staging-deploy-role' -or $current.PolicyName -cne 'bounded-deployment-executor'){throw 'Unexpected policy target.'}
$rendered='jsonencode(jsondecode(local.executor_permission_profile_documents["app_staging"]).statements)' | & terraform "-chdir=$module" console -no-color "-var-file=$PSScriptRoot/render-inputs.json"
if($LASTEXITCODE -ne 0){throw 'Offline policy rendering failed.'}
$policy=($rendered -join "`n" | ConvertFrom-Json) | ConvertFrom-Json -AsHashtable
$ids=@('ReadAndReleaseApplicationSharedFoundationLock','AcquireApplicationSharedFoundationLockConditionally')
$added=@($policy | Where-Object { $_.Sid -in $ids })
if($added.Count -ne 2 -or @($current.PolicyDocument.Statement|Where-Object {$_.Sid -in $ids}).Count -ne 0){throw 'Unexpected lock statement baseline.'}
$newPolicy=$current.PolicyDocument.Clone()
$newPolicy.Statement=@($current.PolicyDocument.Statement)+$added
function Save($value,[string]$name){[IO.File]::WriteAllText("$PSScriptRoot/$name",($value|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false))}
Save $added 'lock-policy-additions.json'
Save $newPolicy 'lock-policy-after.json'
Save ([ordered]@{RoleName=$current.RoleName;PolicyName=$current.PolicyName;PolicyDocument=($newPolicy|ConvertTo-Json -Depth 50 -Compress)}) 'put-role-policy.json'
Save ([ordered]@{RoleName=$current.RoleName;PolicyName=$current.PolicyName;PolicyDocument=($current.PolicyDocument|ConvertTo-Json -Depth 50 -Compress)}) 'rollback-role-policy.json'
Write-Output 'PASS: rendered two exact merged lock statements; no cloud mutation.'
