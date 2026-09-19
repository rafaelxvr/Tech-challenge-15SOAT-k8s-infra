[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$module = Join-Path $root 'infra/modules/deployment-executor'
$before = Get-Content -Raw (Join-Path $PSScriptRoot 'source-before.json') | ConvertFrom-Json -AsHashtable
if ($before.name -cne 'oficina-phase3-oficina-app-staging-deploy' -or $before.source.type -cne 'S3' -or $before.source.location -cne 'oficina-phase3-artifacts-16225b7358/releases/app/staging/bundle.zip') { throw 'Unexpected staging baseline.' }
$rendered = 'jsonencode(local.rendered_deployment_buildspecs["app_staging"])' | & terraform "-chdir=$module" console -no-color "-var-file=$PSScriptRoot/render-inputs.json"
if ($LASTEXITCODE -ne 0) { throw 'Offline Terraform rendering failed.' }
$buildspec = ($rendered -join "`n" | ConvertFrom-Json) | ConvertFrom-Json
foreach ($required in @('reviewed_environment="staging"', 'reviewed_repository="oficina-app"', 'reviewed_backend_key="app/staging.tfstate"', 'reviewed_backend_lock_key="app/staging.tfstate.tflock"', 'reviewed_tfvars_path="/tmp/oficina/app_staging.tfvars.json"', 'reviewed_production_enabled="false"', '-SourceArchiveFile', '-PlatformInputsFile', '-StagingWorkloadFile', '-CloudWindowEvidenceFile')) {
    if (-not $buildspec.Contains($required)) { throw "Rendered buildspec omitted $required" }
}
$candidate = [ordered]@{name=$before.name;source=$before.source.Clone()}
$candidate.source.buildspec = $buildspec
foreach ($entry in @{ 'update-project.json'=$candidate; 'rollback-project.json'=$before }.GetEnumerator()) {
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot $entry.Key), ($entry.Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
}
Write-Output 'PASS: rendered APP staging source update and exact source rollback; no cloud calls.'
