[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$dir=Join-Path (Split-Path -Parent $PSScriptRoot) 'docs/staging-activation/2026-09-19'
function Check([bool]$value,[string]$message){if(-not $value){throw $message}}
$before=Get-Content -Raw "$dir/lock-policy-before.json"|ConvertFrom-Json -AsHashtable
$after=Get-Content -Raw "$dir/lock-policy-after.json"|ConvertFrom-Json -AsHashtable
$update=Get-Content -Raw "$dir/put-role-policy.json"|ConvertFrom-Json -AsHashtable
$rollback=Get-Content -Raw "$dir/rollback-role-policy.json"|ConvertFrom-Json -AsHashtable
Check (($update.Keys -join ',') -ceq 'RoleName,PolicyName,PolicyDocument') 'Unexpected IAM input fields.'
foreach($payload in @($update,$rollback)){
    Check ($payload.RoleName -ceq 'oficina-phase3-oficina-app-staging-deploy-role') 'Production or different role rejected.'
    Check ($payload.PolicyName -ceq 'bounded-deployment-executor') 'Different policy rejected.'
}
Check (($before.PolicyDocument|ConvertTo-Json -Depth 50 -Compress) -ceq $rollback.PolicyDocument) 'Rollback differs from observed policy.'
Check (($after|ConvertTo-Json -Depth 50 -Compress) -ceq $update.PolicyDocument) 'Update payload does not bind expected policy.'
Check ($after.Statement.Count -eq $before.PolicyDocument.Statement.Count+2) 'Exactly two statements required.'
for($i=0;$i -lt $before.PolicyDocument.Statement.Count;$i++){
    Check (($before.PolicyDocument.Statement[$i]|ConvertTo-Json -Depth 50 -Compress) -ceq ($after.Statement[$i]|ConvertTo-Json -Depth 50 -Compress)) 'Existing statement changed.'
}
$added=@($after.Statement|Select-Object -Last 2)
foreach($statement in $added){
    Check ($statement.Effect -ceq 'Allow') 'Unexpected effect.'
    Check ($statement.Resource -ceq 'arn:aws:s3:::oficina-phase3-state-16225b7358/deployment-locks/shared-foundation.json') 'Production, wildcard or different resource rejected.'
}
$read=@($added|Where-Object Sid -eq 'ReadAndReleaseApplicationSharedFoundationLock')[0]
$put=@($added|Where-Object Sid -eq 'AcquireApplicationSharedFoundationLockConditionally')[0]
Check (($read.Action -join ',') -ceq 's3:GetObject,s3:DeleteObject') 'Read/release actions widened.'
Check ($put.Action -ceq 's3:PutObject') 'Acquire action widened.'
Check (($put.Condition|ConvertTo-Json -Compress) -ceq '{"StringEquals":{"s3:if-none-match":"*"}}') 'Atomic acquisition condition missing.'
$hash=(Get-FileHash "$dir/put-role-policy.json").Hash
& "$dir/render-lock-policy.ps1"
Check ($hash -ceq (Get-FileHash "$dir/put-role-policy.json").Hash) 'Policy differs from merged Terraform rendering.'
Write-Output 'PASS: staging-only role, exact shared lock resource/actions, conditional acquisition, unchanged baseline, rollback, merged Terraform rendering.'
