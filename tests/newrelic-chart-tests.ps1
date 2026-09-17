$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$valuesPath = Join-Path $repositoryRoot 'observability/newrelic-values.yaml'
$secretSyncPath = Join-Path $repositoryRoot 'observability/newrelic-secret-sync.yaml'
$renderer = Join-Path $repositoryRoot 'scripts/render-newrelic-bundle.ps1'
$values = Get-Content -LiteralPath $valuesPath -Raw
$secretSync = Get-Content -LiteralPath $secretSyncPath -Raw
$rendererSource = Get-Content -LiteralPath $renderer -Raw
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($renderer, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ('New Relic chart renderer has a PowerShell syntax error: ' + $parseErrors[0].Message) }

function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) {
    if (-not $Text.Contains($Expected)) { throw $Message }
}

Assert-Contains $values 'lowDataMode: true' 'The bundle must remain in low-data mode.'
Assert-Contains $values 'customAttributes:' 'Kubernetes samples need an explicit dashboard environment attribute.'
Assert-Contains $values 'environment: ${environment}' 'The environment attribute must remain a deployment-time finite value.'
Assert-Contains $values 'config:' 'Infrastructure agent configuration is required for supported collection settings.'
Assert-Contains $values 'interval: 30s' 'Kubernetes collection must use the approved 30-second low-data interval.'
Assert-Contains $secretSync 'namespace: newrelic' 'The chart credential must be synchronized in the collector namespace.'
Assert-Contains $secretSync 'serviceAccountName: newrelic-ingest-secret-sync' 'CSI sync must not use the default ServiceAccount.'
Assert-Contains $secretSync 'eks.amazonaws.com/role-arn' 'CSI sync must use its existing least-privilege IRSA role.'
Assert-Contains $secretSync 'key: license-key' 'The synced credential key must match global.customSecretLicenseKey.'
Assert-Contains $secretSync '${ingest_secret_arn}' 'The sync must use the reviewed existing environment source ARN.'
Assert-Contains $values 'pixie-chart:' 'Pixie must remain explicitly disabled.'
Assert-Contains $values 'prometheus:' 'Duplicate Prometheus scraping must remain explicitly disabled.'
Assert-Contains $rendererSource 'template nri-bundle nri-bundle' 'The renderer must invoke Helm against the pinned bundle.'
Assert-Contains $rendererSource '--version 5.0.94' 'The renderer must use the exact reviewed chart version.'
Assert-Contains $rendererSource 'collectorWorkloads' 'The renderer must emit actual rendered collector resource accounting.'
Assert-Contains $rendererSource 'requestBlock' 'Collector accounting must sum only resources.requests, never limits.'

$helm = Get-Command helm -ErrorAction SilentlyContinue
if ($null -eq $helm) {
    Write-Output 'PASS: static New Relic chart configuration checks passed; Helm is unavailable, so dynamic schema/render accounting remains for a Helm-equipped CI runner.'
    exit 0
}

$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("oficina-nri-render-" + [guid]::NewGuid().ToString('N'))
try {
    $accountingPath = & $renderer -Environment staging -ClusterName oficina-phase3 -IngestSecretName newrelic-staging-ingest -IngestSecretArn arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-AbCdEf -SecretSyncIrsaRoleArn arn:aws:iam::123456789012:role/oficina-staging-newrelic-secret-sync -OutputDirectory $temporary
    $accounting = Get-Content -LiteralPath $accountingPath -Raw | ConvertFrom-Json
    if ($accounting.chartVersion -ne '5.0.94' -or $accounting.collectionInterval -ne '30s') { throw 'Rendered accounting did not retain the pinned chart or approved interval.' }
    if (@($accounting.collectorWorkloads).Count -lt 3) { throw 'Rendered chart resource accounting is missing an approved collector workload.' }
    if ($accounting.totalRequestedCpuMilli -le 0 -or $accounting.totalRequestedMemoryMiB -le 0) { throw 'Rendered collector accounting must contain concrete resource requests.' }
    Write-Output 'PASS: New Relic chart schema/render validation and collector resource accounting passed.'
}
finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
