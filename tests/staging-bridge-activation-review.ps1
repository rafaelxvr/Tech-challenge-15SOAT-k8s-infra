[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$dir=Join-Path $root 'docs/staging-activation/2026-09-19'
$before=Get-Content -Raw "$dir/source-before.json" | ConvertFrom-Json -AsHashtable
$update=Get-Content -Raw "$dir/update-project.json" | ConvertFrom-Json -AsHashtable
$rollback=Get-Content -Raw "$dir/rollback-project.json" | ConvertFrom-Json -AsHashtable
function Check([bool]$condition,[string]$message) { if(-not $condition){throw $message} }
Check (($update.Keys -join ',') -ceq 'name,source') 'Mutation payload must contain name/source only.'
Check ($update.name -ceq 'oficina-phase3-oficina-app-staging-deploy') 'Only the staging APP project may change.'
Check (($before|ConvertTo-Json -Depth 30 -Compress) -ceq ($rollback|ConvertTo-Json -Depth 30 -Compress)) 'Rollback must match exact baseline source.'
Check (($before.source.Keys -join ',') -ceq ($update.source.Keys -join ',')) 'Source field set changed.'
foreach($key in $before.source.Keys) {
    if($key -ne 'buildspec') { Check (($before.source[$key]|ConvertTo-Json -Depth 30 -Compress) -ceq ($update.source[$key]|ConvertTo-Json -Depth 30 -Compress)) "Unexpected source change: $key" }
}
Check (-not $before.source.buildspec.Contains('app_staging_switch')) 'Baseline unexpectedly already has the bridge.'
Check ($update.source.buildspec.Contains('app_staging_switch')) 'Candidate lacks the reviewed bridge.'
$inputs=Get-Content -Raw "$dir/render-inputs.json" | ConvertFrom-Json -AsHashtable
Check ($inputs.production_input_bindings.Count -eq 0) 'Production binding must stay empty.'
foreach($entry in $inputs.deployments.Values) { if($entry.environment -eq 'production'){Check ($entry.deployment_mode -ceq 'plan') 'Production render fixture cannot enable apply.'} }
$expected=(Get-FileHash "$dir/update-project.json").Hash
& "$dir/render.ps1"
Check ($expected -ceq (Get-FileHash "$dir/update-project.json").Hash) 'Committed payload differs from current Terraform rendering.'
$script=($update.source.buildspec -split "`n" | Select-Object -Skip 5 | ForEach-Object { $_ -replace '^        ','' }) -join "`n"
$temp=Join-Path ([IO.Path]::GetTempPath()) "staging-bridge-$([guid]::NewGuid()).sh"
try {
    [IO.File]::WriteAllText($temp,$script,[Text.UTF8Encoding]::new($false))
    $bash=if($IsWindows){'C:/Program Files/Git/bin/bash.exe'}else{'bash'}
    & $bash -n $temp
    Check ($LASTEXITCODE -eq 0) 'Rendered Bash syntax failed.'
} finally { Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue }
Write-Output 'PASS: exact Terraform rendering, source-only scope, rollback, disabled production, Bash syntax.'
