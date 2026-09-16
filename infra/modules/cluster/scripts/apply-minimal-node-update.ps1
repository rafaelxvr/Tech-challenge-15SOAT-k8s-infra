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
    [int]$MaxUnavailable = 1,
    [ValidateRange(1, 120)]
    [int]$MaxPolls = 120
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

    for ($poll = 1; $poll -le $MaxPolls; $poll++) {
        $update = Invoke-EksJson -Arguments @('eks', 'describe-update', '--name', $ClusterName, '--nodegroup-name', $NodeGroupName, '--update-id', $UpdateId)
        switch ($update.update.status) {
            'Successful' { return }
            'Failed' { throw "EKS update failed for node group ${NodeGroupName}: $(Get-SafeUpdateDetails -Update $update)." }
            'Cancelled' { throw "EKS update was cancelled for node group ${NodeGroupName}: $(Get-SafeUpdateDetails -Update $update)." }
            'InProgress' { Start-Sleep -Seconds 5 }
            default { throw "EKS update returned an unexpected terminal state for node group ${NodeGroupName}: $(Get-SafeUpdateDetails -Update $update)." }
        }
    }
    throw "EKS update did not reach Successful within $MaxPolls polls for node group ${NodeGroupName}: $(Get-SafeUpdateDetails -Update $update)."
}

function Get-SafeUpdateDetails {
    param([Parameter(Mandatory)]$Update)

    $errorCodes = @()
    if ($null -ne $Update.update.errors) {
        $errorCodes = @($Update.update.errors | ForEach-Object { [string]$_.errorCode } | Where-Object { $_ })
    }
    $status = [string]$Update.update.status
    $type = [string]$Update.update.type
    $codeSummary = if ($errorCodes.Count -gt 0) { $errorCodes -join ',' } else { 'none' }
    return "status=$status;type=$type;errorCodes=$codeSummary"
}

function New-EksClientRequestToken {
    param(
        [Parameter(Mandatory)][ValidateSet('config', 'version')][string]$Operation,
        [Parameter(Mandatory)][string]$NodeGroupName,
        [Parameter(Mandatory)][string]$DesiredValue
    )

    $payload = "$ClusterName|$NodeGroupName|$Operation|$DesiredValue|$UpdateStrategy|$MaxUnavailable"
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    return "oficina-$Operation-$($hash.Substring(0, 48))"
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
        '--client-request-token', (New-EksClientRequestToken -Operation config -NodeGroupName $nodeGroupName -DesiredValue "maxUnavailable=$MaxUnavailable,updateStrategy=$UpdateStrategy")
    )
    Wait-EksUpdate -NodeGroupName $nodeGroupName -UpdateId $configuration.update.id

    $nodeGroup = Invoke-EksJson -Arguments @('eks', 'describe-nodegroup', '--cluster-name', $ClusterName, '--nodegroup-name', $nodeGroupName)
    if ($nodeGroup.nodegroup.releaseVersion -eq $targetReleaseVersion) {
        continue
    }

    $version = Invoke-EksJson -Arguments @(
        'eks', 'update-nodegroup-version', '--cluster-name', $ClusterName, '--nodegroup-name', $nodeGroupName,
        '--release-version', $targetReleaseVersion, '--client-request-token', (New-EksClientRequestToken -Operation version -NodeGroupName $nodeGroupName -DesiredValue $targetReleaseVersion)
    )
    Wait-EksUpdate -NodeGroupName $nodeGroupName -UpdateId $version.update.id
}
