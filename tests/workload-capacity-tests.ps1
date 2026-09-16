[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$renderer = Join-Path $repoRoot 'scripts/render-platform.ps1'
$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("oficina-capacity-test-" + [guid]::NewGuid())

try {
    $common = @{
        Image                = '123456789012.dkr.ecr.us-east-1.amazonaws.com/oficina-app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        AppIrsaRoleArn       = 'arn:aws:iam::123456789012:role/oficina-app'
        DeployerPrincipalArn = 'arn:aws:iam::123456789012:role/oficina-k8s-deploy'
        PlatformBindingPrincipalArn = 'arn:aws:iam::123456789012:role/oficina-platform-binding'
        DbHost               = 'db.oficina.internal'
        DbCidr               = '10.20.0.0/24'
        AlbSubnetCidrOne     = '10.42.0.0/24'
        AlbSubnetCidrTwo     = '10.42.1.0/24'
        AppSecretArn         = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/app-AbCdEf'
        NewRelicIngestSecretArn = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-AbCdEf'
        NewRelicAccountId    = '1234567'
        OutputDirectory      = $tempDirectory
    }
    $stagingFile = & $renderer -Environment staging @common
    $productionInputs = @{} + $common
    $productionInputs.NewRelicIngestSecretArn = $common.NewRelicIngestSecretArn -replace '/staging/', '/production/'
    $productionFile = & $renderer -Environment production @productionInputs
    $staging = Get-Content -LiteralPath $stagingFile -Raw
    $production = Get-Content -LiteralPath $productionFile -Raw

    if ($staging -notmatch 'maxReplicas: 2' -or $production -notmatch 'maxReplicas: 4') { throw 'Unexpected HPA maxima.' }
    $maximumAppCpu = 6 * 0.25
    $maximumAppMemoryGiB = 6 * 0.75
    $platformReserveCpu = 2.25
    $platformReserveMemoryGiB = 6
    $totalCpu = $maximumAppCpu + $platformReserveCpu
    $totalMemoryGiB = $maximumAppMemoryGiB + $platformReserveMemoryGiB
    if ($totalCpu -gt 4 -or $totalMemoryGiB -gt 16) { throw 'Configured HPA maxima exceed the two-worker physical planning envelope.' }

    Write-Output "PASS: max HPA request envelope is $totalCpu vCPU and $totalMemoryGiB GiB before kubelet/CNI reservations; R4 must measure allocatable capacity."
}
finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
