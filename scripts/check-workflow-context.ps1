[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('staging','production')][string]$Environment,
    [string]$EventName = $env:GITHUB_EVENT_NAME,
    [string]$BranchRef = $env:GITHUB_REF
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$expected = if ($Environment -ceq 'staging') { 'refs/heads/develop' } else { 'refs/heads/main' }
if ($EventName -cne 'push' -or $BranchRef -cne $expected) { throw 'Deployment context must be a push to the exact protected environment branch.' }
Write-Output 'Protected branch mapping validated; external GitHub protection is still required.'
