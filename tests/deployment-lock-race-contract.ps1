[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lock = Join-Path $PSScriptRoot '../scripts/deployment-lock.ps1'
$deployerDockerfile = Join-Path $PSScriptRoot '../images/deployer/Dockerfile'
if ((Test-Path -LiteralPath $deployerDockerfile) -and (Get-Content -LiteralPath $deployerDockerfile -Raw) -notmatch '(?m)^ARG AWS_CLI_VERSION=2\.36\.42\s*$') { throw 'Reviewed deployer CLI must support conditional S3 DeleteObject.' }
$ownerA = '11111111-1111-1111-1111-111111111111'
$ownerB = '22222222-2222-2222-2222-222222222222'
$global:DeploymentLockRaceFixture = @{}
function aws {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    switch ("$($arguments[0]) $($arguments[1])") {
        's3api head-object' {
            $head = @{ Metadata = @{ owner = $global:DeploymentLockRaceFixture.owner }; ETag = $global:DeploymentLockRaceFixture.etag }
            if ($global:DeploymentLockRaceFixture.mode -eq 'replace-after-head') {
                # Deterministic interleaving: another release removes A and B
                # acquires the same key after this HEAD snapshot, before DELETE.
                $global:DeploymentLockRaceFixture.owner = $ownerB
                $global:DeploymentLockRaceFixture.etag = '"etag-owner-B"'
            }
            return ($head | ConvertTo-Json -Compress)
        }
        's3api delete-object' {
            $global:DeploymentLockRaceFixture.deletes++
            $index = [Array]::IndexOf($arguments, '--if-match')
            $condition = if ($index -ge 0) { $arguments[$index + 1] } else { $null }
            $global:DeploymentLockRaceFixture.condition = $condition
            # Model S3 conditional semantics. An unconditional old implementation
            # would delete B and cause the regression assertions below to fail.
            if ($null -ne $condition -and $condition -cne $global:DeploymentLockRaceFixture.etag) { $global:LASTEXITCODE = 412; return '{}' }
            $global:DeploymentLockRaceFixture.owner = $null
            return '{}'
        }
        default { throw 'No real AWS operation is allowed in this fixture.' }
    }
}
function Release-A {
    & $lock -Action Release -StateBucket 'oficina-state-fixture' -OwnerToken $ownerA | Out-Null
}
function Rejected([scriptblock]$Action) {
    try { & $Action } catch { return }
    throw 'Expected release to fail closed.'
}
$global:DeploymentLockRaceFixture = @{ mode='replace-after-head'; owner=$ownerA; etag='"etag-owner-A"'; deletes=0; condition=$null }
Rejected { Release-A }
if ($global:DeploymentLockRaceFixture.owner -cne $ownerB -or $global:DeploymentLockRaceFixture.deletes -ne 1 -or $global:DeploymentLockRaceFixture.condition -cne '"etag-owner-A"') { throw 'Stale owner A deleted or retried against replacement owner B.' }
$global:DeploymentLockRaceFixture = @{ mode='normal'; owner=$ownerA; etag='"etag-owner-A"'; deletes=0; condition=$null }
Release-A
if ($null -ne $global:DeploymentLockRaceFixture.owner -or $global:DeploymentLockRaceFixture.condition -cne '"etag-owner-A"') { throw 'An unchanged owned lock must release conditionally.' }
$global:DeploymentLockRaceFixture = @{ mode='normal'; owner=$ownerB; etag='"etag-owner-B"'; deletes=0; condition=$null }
Rejected { Release-A }
if ($global:DeploymentLockRaceFixture.deletes -ne 0 -or $global:DeploymentLockRaceFixture.owner -cne $ownerB) { throw 'Foreign owner must never attempt deletion.' }
foreach ($invalid in @($null, '', '*', '"*"', "`"etag`nheader`"")) {
    $global:DeploymentLockRaceFixture = @{ mode='normal'; owner=$ownerA; etag=$invalid; deletes=0; condition=$null }
    Rejected { Release-A }
    if ($global:DeploymentLockRaceFixture.deletes -ne 0) { throw 'Missing, wildcard or malformed ETag must not reach DELETE.' }
}
Write-Output 'PASS: deterministic HEAD/delete interleaving preserves successor B; exact-owner release and invalid ETag rejection verified with AWS mocked.'
