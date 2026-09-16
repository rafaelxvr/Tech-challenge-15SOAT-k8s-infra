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
        TargetGroupArn       = 'arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/oficina/1234567890abcdef'
        AppIrsaRoleArn       = 'arn:aws:iam::123456789012:role/oficina-app'
        DeployerPrincipalArn = 'arn:aws:iam::123456789012:role/oficina-k8s-deploy'
        DbHost               = 'db.oficina.internal'
        DbCidr               = '10.20.0.0/24'
        VpcCidr              = '10.0.0.0/16'
        AppSecretArn         = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/app-AbCdEf'
        OutputDirectory      = $tempDirectory
    }
    $stagingFile = & $renderer -Environment staging @common
    $productionFile = & $renderer -Environment production @common
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
