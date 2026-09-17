[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('staging', 'production')]
    [string]$Environment,
    [Parameter(Mandatory)]
    [string]$ClusterName,
    [Parameter(Mandatory)]
    [string]$IngestSecretName,
    [Parameter(Mandatory)]
    [string]$IngestSecretArn,
    [Parameter(Mandatory)]
    [string]$SecretSyncIrsaRoleArn,
    [Parameter(Mandatory)]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$helm = Get-Command helm -ErrorAction SilentlyContinue
if ($null -eq $helm) { throw 'Helm CLI is required to render the pinned nri-bundle chart.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $repositoryRoot 'observability/newrelic-values.yaml'
$secretSyncTemplatePath = Join-Path $repositoryRoot 'observability/newrelic-secret-sync.yaml'
$valuesPath = Join-Path $OutputDirectory ("newrelic-values-{0}.yaml" -f $Environment)
$manifestPath = Join-Path $OutputDirectory ("nri-bundle-{0}.yaml" -f $Environment)
$accountingPath = Join-Path $OutputDirectory ("nri-bundle-{0}-resources.json" -f $Environment)

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$values = (Get-Content -LiteralPath $templatePath -Raw).
    Replace('${cluster_name}', $ClusterName).
    Replace('${environment}', $Environment).
    Replace('${ingest_secret_name}', $IngestSecretName)
if ($values -match '\$\{[A-Za-z_]+\}') { throw 'New Relic values contain an unresolved deployment token.' }
Set-Content -LiteralPath $valuesPath -Value $values -NoNewline

# `helm template` validates the pinned chart's values schema before producing the manifest.
$renderedManifest = & $helm.Source template nri-bundle nri-bundle `
    --repo https://helm-charts.newrelic.com `
    --version 5.0.94 `
    --namespace newrelic `
    --values $valuesPath
if ($LASTEXITCODE -ne 0) { throw 'Pinned nri-bundle schema/render validation failed.' }
($renderedManifest -join [Environment]::NewLine) | Set-Content -LiteralPath $manifestPath -NoNewline

$secretSync = (Get-Content -LiteralPath $secretSyncTemplatePath -Raw).
    Replace('${ingest_secret_name}', $IngestSecretName).
    Replace('${ingest_secret_arn}', $IngestSecretArn).
    Replace('${secret_sync_irsa_role_arn}', $SecretSyncIrsaRoleArn)
if ($secretSync -match '\$\{[A-Za-z_]+\}') { throw 'New Relic secret-sync manifest contains an unresolved deployment token.' }
Add-Content -LiteralPath $manifestPath -Value ("`n---`n" + $secretSync)

$manifest = Get-Content -LiteralPath $manifestPath -Raw
foreach ($collector in @('newrelic-infrastructure', 'kube-state-metrics', 'newrelic-logging')) {
    if (-not $manifest.Contains($collector)) { throw "Rendered nri-bundle is missing approved collector $collector." }
}
if (-not $manifest.Contains("secretName: $IngestSecretName") -or -not $manifest.Contains('key: license-key') -or -not $manifest.Contains($IngestSecretArn)) { throw 'Rendered collector credentials must sync the exact environment ingest secret as license-key in the newrelic namespace.' }
if ($manifest -match '(?m)^kind: (?:Deployment|DaemonSet|StatefulSet)\r?$') {
    # Continue to account below. This branch makes an empty render an explicit failure.
} else {
    throw 'Pinned nri-bundle render contains no collector workload resources.'
}

function Convert-CpuToMilli([string]$Value) {
    if ($Value -match '^([0-9]+)m$') { return [int]$Matches[1] }
    if ($Value -match '^[0-9]+$') { return [int]$Value * 1000 }
    throw "Unsupported CPU request value: $Value"
}

function Convert-MemoryToMiB([string]$Value) {
    if ($Value -match '^([0-9]+)Mi$') { return [int]$Matches[1] }
    if ($Value -match '^([0-9]+)Gi$') { return [int]$Matches[1] * 1024 }
    throw "Unsupported memory request value: $Value"
}

$workloads = @()
foreach ($document in ($manifest -split '(?m)^---\s*$')) {
    if ($document -notmatch '(?m)^kind: (DaemonSet|Deployment|StatefulSet)\r?$') { continue }
    $kind = $Matches[1]
    if ($document -notmatch '(?ms)^metadata:\s*.*?^\s+name:\s*([^\s]+)') { continue }
    $name = $Matches[1]
    if ($name -notmatch '(newrelic|nri-bundle-nrk8|kube-state-metrics)') { continue }

    # Account only requests. Limits are deliberately not added to the scheduling envelope.
    $requestBlocks = [regex]::Matches($document, '(?ms)^\s*requests:\s*\r?\n(?<requestBlock>.*?)(?=^\s*limits:|^\s*resources:|\z)')
    $cpu = 0
    foreach ($requestBlock in $requestBlocks) {
        foreach ($match in [regex]::Matches($requestBlock.Groups['requestBlock'].Value, '(?m)^\s*cpu:\s*([^\s#]+)')) { $cpu += Convert-CpuToMilli $match.Groups[1].Value }
    }
    $memory = 0
    foreach ($requestBlock in $requestBlocks) {
        foreach ($match in [regex]::Matches($requestBlock.Groups['requestBlock'].Value, '(?m)^\s*memory:\s*([^\s#]+)')) { $memory += Convert-MemoryToMiB $match.Groups[1].Value }
    }
    $workloads += [pscustomobject]@{ kind = $kind; name = $name; requestedCpuMilli = $cpu; requestedMemoryMiB = $memory }
}
if ($workloads.Count -lt 3) { throw 'Rendered bundle must account for the approved infrastructure, KSM and logging collector workloads.' }

$report = [ordered]@{
    chart = 'nri-bundle'
    chartVersion = '5.0.94'
    environment = $Environment
    collectionInterval = '30s'
    collectorWorkloads = $workloads
    totalRequestedCpuMilli = @($workloads | Measure-Object -Property requestedCpuMilli -Sum).Sum
    totalRequestedMemoryMiB = @($workloads | Measure-Object -Property requestedMemoryMiB -Sum).Sum
}
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $accountingPath -NoNewline
Write-Output $accountingPath
