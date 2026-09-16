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
Assert-Contains $terraform 'node_update_max_polls\s*=\s*120' 'The Terraform executor must set a finite update-poll limit.'
Assert-Contains $terraform 'interpreter\s*=\s*\["pwsh",\s*"-NoLogo",\s*"-NoProfile",\s*"-File",\s*"\$\{path\.module\}/scripts/apply-minimal-node-update\.ps1"\]' 'pwsh -File must receive the minimal-update script path as its file argument.'
Assert-Contains $terraform 'command\s*=\s*"-Region \$\{var\.aws_region\}' 'The local-exec command must pass parameters after the -File script path.'
Assert-Contains $executor "update-nodegroup-config'.*--cluster-name" 'The executor must configure the real EKS node group.'
Assert-Contains $executor 'maxUnavailable=\$MaxUnavailable,updateStrategy=\$UpdateStrategy' 'The executor must configure both bounded unavailability and MINIMAL strategy.'
Assert-Contains $executor '(?s)update-nodegroup-version.*--release-version' 'The executor must perform version changes only after configuration.'
Assert-Contains $executor 'Sort-Object Name' 'The executor must update node groups serially in a stable order.'
Assert-Contains $executor 'for \(\$poll = 1; \$poll -le \$MaxPolls; \$poll\+\+\)' 'Polling must be bounded by MaxPolls.'
Assert-Contains $executor 'unexpected terminal state' 'Unknown update states must fail closed.'
Assert-Contains $executor 'New-EksClientRequestToken' 'Updates must use deterministic idempotency tokens.'
Assert-Contains $executor 'SHA256.*HashData' 'Client request tokens must be derived from the desired operation, not generated randomly.'
if ($executor -match 'NewGuid\(\)') { throw 'EKS update client request tokens must not be random GUIDs.' }
if ($executor.IndexOf('update-nodegroup-config') -ge $executor.IndexOf('update-nodegroup-version')) { throw 'Node-group configuration must be submitted before a version update.' }

Write-Output 'cluster update executor contract: PASS'
