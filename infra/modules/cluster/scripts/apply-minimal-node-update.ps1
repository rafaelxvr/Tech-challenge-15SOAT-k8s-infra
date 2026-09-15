[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Region,
    [Parameter(Mandatory)]
    [string]$ClusterName,
    [Parameter(Mandatory)]
    [string]$NodeGroupReleaseVersionsJson,
    [ValidateSet('MINIMAL')]
    [string]$UpdateStrategy = 'MINIMAL',
    [ValidateRange(1, 1)]
    [int]$MaxUnavailable = 1
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-EksJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = & aws @Arguments --region $Region --output json
    if ($LASTEXITCODE -ne 0) {
        throw "EKS CLI command failed: $($Arguments[0])"
    }
    return $result | ConvertFrom-Json
}

function Wait-EksUpdate {
    param(
        [Parameter(Mandatory)][string]$NodeGroupName,
        [Parameter(Mandatory)][string]$UpdateId
    )

    while ($true) {
        $update = Invoke-EksJson -Arguments @('eks', 'describe-update', '--name', $ClusterName, '--nodegroup-name', $NodeGroupName, '--update-id', $UpdateId)
        switch ($update.update.status) {
            'Successful' { return }
            'Failed' { throw "EKS update failed for node group $NodeGroupName." }
            'Cancelled' { throw "EKS update was cancelled for node group $NodeGroupName." }
            default { Start-Sleep -Seconds 5 }
        }
    }
}

$releaseVersions = $NodeGroupReleaseVersionsJson | ConvertFrom-Json
foreach ($entry in @($releaseVersions.PSObject.Properties | Sort-Object Name)) {
    $nodeGroupName = $entry.Name
    $targetReleaseVersion = [string]$entry.Value

    # EKS applies this configuration before any version operation. The loop is
    # intentionally serial: a second worker cannot begin replacement first.
    $configuration = Invoke-EksJson -Arguments @(
        'eks', 'update-nodegroup-config', '--cluster-name', $ClusterName, '--nodegroup-name', $nodeGroupName,
        '--update-config', "maxUnavailable=$MaxUnavailable,updateStrategy=$UpdateStrategy",
        '--client-request-token', [guid]::NewGuid().ToString()
    )
    Wait-EksUpdate -NodeGroupName $nodeGroupName -UpdateId $configuration.update.id

    $nodeGroup = Invoke-EksJson -Arguments @('eks', 'describe-nodegroup', '--cluster-name', $ClusterName, '--nodegroup-name', $nodeGroupName)
    if ($nodeGroup.nodegroup.releaseVersion -eq $targetReleaseVersion) {
        continue
    }

    $version = Invoke-EksJson -Arguments @(
        'eks', 'update-nodegroup-version', '--cluster-name', $ClusterName, '--nodegroup-name', $nodeGroupName,
        '--release-version', $targetReleaseVersion, '--client-request-token', [guid]::NewGuid().ToString()
    )
    Wait-EksUpdate -NodeGroupName $nodeGroupName -UpdateId $version.update.id
}
