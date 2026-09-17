[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$check = Join-Path $PSScriptRoot '../scripts/check-workflow-context.ps1'
$count = 0
foreach ($environment in @('staging','production')) {
    $expected = if ($environment -eq 'staging') { 'refs/heads/develop' } else { 'refs/heads/main' }
    & $check -Environment $environment -EventName push -BranchRef $expected | Out-Null
    $count++
    foreach ($eventName in @('pull_request','pull_request_target','workflow_dispatch','schedule')) {
        $rejected = $false
        try { & $check -Environment $environment -EventName $eventName -BranchRef $expected | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw "Unexpected deploy context: $eventName/$environment" }; $count++
    }
    foreach ($branch in @('refs/heads/master','refs/heads/feature','refs/tags/main', $(if ($environment -eq 'staging') {'refs/heads/main'}else{'refs/heads/develop'}))) {
        $rejected = $false
        try { & $check -Environment $environment -EventName push -BranchRef $branch | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw "Unexpected deploy branch: $branch/$environment" }; $count++
    }
}
$repo = Split-Path -Parent $PSScriptRoot
$workflowPath = Join-Path $repo '.github/workflows/ci-cd.yml'
if (-not (Test-Path -LiteralPath $workflowPath)) { $workflowPath = Join-Path $repo '.github/workflows/ci.yml' }
$workflow = Get-Content -LiteralPath $workflowPath -Raw
if ($workflow -match 'pull_request_target|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|refs/heads/master') { throw 'Workflow contains an unapproved event, branch or fixed deployment credential.' }
foreach ($job in ($workflow -split '(?m)(?=^  [a-z][a-z0-9-]+:\s*$)')) {
    if ($job -notmatch 'id-token: write|packages: write') { continue }
    if ($job -notmatch "if: github.event_name == 'push'") { throw 'A pull request could receive a publishing/deployment identity.' }
    if ($job -match 'id-token: write') {
        if ($job -notmatch 'cancel-in-progress: false|check-workflow-context.ps1') { throw 'Deployment needs non-cancelling concurrency and an explicit context guard.' }
        foreach ($required in @('cancel-in-progress: false','check-workflow-context.ps1','needs: verify')) {
            if (-not $job.Contains($required)) { throw "Deployment job lacks $required." }
        }
        if ($job -match 'environment: production' -and $job -notmatch "github.ref == 'refs/heads/main'") { throw 'Production job must require main.' }
        if ($job -match 'environment: staging' -and $job -notmatch "github.ref == 'refs/heads/develop'") { throw 'Staging job must require develop.' }
    }
}
Write-Output "PASS: $count branch/event mapping contracts and workflow identity boundaries."
