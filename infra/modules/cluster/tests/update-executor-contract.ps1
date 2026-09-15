$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$moduleRoot = Split-Path -Parent $PSScriptRoot
$terraform = Get-Content -Raw -LiteralPath (Join-Path $moduleRoot 'main.tf')
$executor = Get-Content -Raw -LiteralPath (Join-Path $moduleRoot 'scripts/apply-minimal-node-update.ps1')

function Assert-Contains {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -notmatch $Pattern) { throw $Message }
}

Assert-Contains $terraform 'ignore_changes\s*=\s*\[release_version\]' 'Terraform provider release updates must be disabled so DEFAULT surge cannot run first.'
Assert-Contains $terraform 'resource "terraform_data" "workers_minimal_update"' 'The controlled node-update executor must be a Terraform apply dependency.'
Assert-Contains $terraform 'update_strategy\s*=\s*local\.node_update_strategy' 'The executor trigger must pin MINIMAL.'
Assert-Contains $executor "update-nodegroup-config'.*--cluster-name" 'The executor must configure the real EKS node group.'
Assert-Contains $executor 'maxUnavailable=\$MaxUnavailable,updateStrategy=\$UpdateStrategy' 'The executor must configure both bounded unavailability and MINIMAL strategy.'
Assert-Contains $executor '(?s)update-nodegroup-version.*--release-version' 'The executor must perform version changes only after configuration.'
Assert-Contains $executor 'Sort-Object Name' 'The executor must update node groups serially in a stable order.'
if ($executor.IndexOf('update-nodegroup-config') -ge $executor.IndexOf('update-nodegroup-version')) { throw 'Node-group configuration must be submitted before a version update.' }

Write-Output 'cluster update executor contract: PASS'
