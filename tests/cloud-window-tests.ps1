[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $repoRoot 'scripts/check-cloud-window.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('oficina-cloud-window-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
$evidenceFile = Join-Path $temp 'evidence.json'
$now = '2026-09-16T15:00:00Z'
$script:assertions = 0

function New-Evidence([string]$Mode = 'numeric-budget') {
    $record = @{
        windowStartUtc = '2026-09-16T14:00:00Z'
        windowEndUtc = '2026-09-16T16:00:00Z'
        recordedAtUtc = '2026-09-16T14:55:00Z'
        accountEvidenceReference = 'offline-test-account-review'
    }
    if ($Mode -eq 'numeric-budget') {
        $record.projectAllowanceUsd = 80
        $record.reserveUsd = 20
        $record.currentEstimatedSpendUsd = 10
    } else {
        $record.costAuthorization = 'billing-acknowledgment'
        $record.environment = 'staging'
        $record.scope = 'study-staging'
        $record.billingBeyondFreeCreditsAcknowledged = $true
        $record.approvalReference = 'offline-test-explicit-staging-billing-approval'
    }
    return $record
}

function Check-Record([hashtable]$Record, [string]$Target = '', [bool]$Accept = $true, [string]$Label = '') {
    $Record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $evidenceFile -NoNewline
    $arguments = @{ EvidenceFile = $evidenceFile; NowUtc = $now }
    if ($Target) { $arguments.Environment = $Target }
    $failure = $null
    try { & $validator @arguments | Out-Null } catch { $failure = $_ }
    if ($Accept -and $null -ne $failure) { throw "ASSERTION FAILED: $Label should pass: $failure" }
    if (-not $Accept -and $null -eq $failure) { throw "ASSERTION FAILED: $Label should reject." }
    $script:assertions++
}

try {
    Check-Record (New-Evidence) '' $true 'legacy numeric evidence without mode or environment'
    $numeric = New-Evidence
    $numeric.costAuthorization = 'numeric-budget'
    Check-Record $numeric 'production' $true 'explicit numeric mode remains valid for production'
    Check-Record (New-Evidence 'billing-acknowledgment') 'staging' $true 'explicit study staging billing approval without a fabricated USD cap'

    foreach ($mode in @('numeric-budget', 'billing-acknowledgment')) {
        foreach ($missing in @('windowStartUtc', 'windowEndUtc', 'recordedAtUtc', 'accountEvidenceReference')) {
            $record = New-Evidence $mode; $record.Remove($missing)
            Check-Record $record 'staging' $false "$mode missing $missing"
        }
        foreach ($invalid in @(
            @{ field = 'recordedAtUtc'; value = '2026-09-15T14:59:59Z' },
            @{ field = 'recordedAtUtc'; value = '2026-09-16T15:05:01Z' },
            @{ field = 'windowStartUtc'; value = '2026-09-16T15:00:01Z' },
            @{ field = 'windowEndUtc'; value = '2026-09-16T14:59:59Z' },
            @{ field = 'windowStartUtc'; value = '2026-09-16T17:00:00Z' },
            @{ field = 'recordedAtUtc'; value = 'invalid-timestamp' }
        )) {
            $record = New-Evidence $mode; $record[$invalid.field] = $invalid.value
            Check-Record $record 'staging' $false "$mode invalid $($invalid.field): $($invalid.value)"
        }
    }

    foreach ($missing in @('projectAllowanceUsd', 'reserveUsd', 'currentEstimatedSpendUsd')) {
        $record = New-Evidence; $record.Remove($missing)
        Check-Record $record 'staging' $false "numeric mode missing $missing"
    }
    foreach ($invalid in @(
        @{ field = 'projectAllowanceUsd'; value = 0 },
        @{ field = 'reserveUsd'; value = -1 },
        @{ field = 'reserveUsd'; value = 80 },
        @{ field = 'currentEstimatedSpendUsd'; value = -1 },
        @{ field = 'currentEstimatedSpendUsd'; value = 61 },
        @{ field = 'projectAllowanceUsd'; value = 'not-a-number' }
    )) {
        $record = New-Evidence; $record[$invalid.field] = $invalid.value
        Check-Record $record 'staging' $false "numeric invalid $($invalid.field): $($invalid.value)"
    }

    foreach ($target in @('', 'production', 'foundation')) {
        Check-Record (New-Evidence 'billing-acknowledgment') $target $false "billing acknowledgment cannot target '$target'"
    }
    foreach ($missing in @('environment', 'scope', 'billingBeyondFreeCreditsAcknowledged', 'approvalReference')) {
        $record = New-Evidence 'billing-acknowledgment'; $record.Remove($missing)
        Check-Record $record 'staging' $false "billing acknowledgment missing $missing"
    }
    foreach ($invalid in @(
        @{ field = 'environment'; value = 'production' },
        @{ field = 'environment'; value = @('staging', 'production') },
        @{ field = 'scope'; value = 'all-environments' },
        @{ field = 'scope'; value = @('study-staging') },
        @{ field = 'billingBeyondFreeCreditsAcknowledged'; value = $false },
        @{ field = 'billingBeyondFreeCreditsAcknowledged'; value = 'true' },
        @{ field = 'billingBeyondFreeCreditsAcknowledged'; value = 1 },
        @{ field = 'billingBeyondFreeCreditsAcknowledged'; value = @($true) },
        @{ field = 'approvalReference'; value = ' ' },
        @{ field = 'approvalReference'; value = @('approval') },
        @{ field = 'costAuthorization'; value = 'unknown' }
    )) {
        $record = New-Evidence 'billing-acknowledgment'; $record[$invalid.field] = $invalid.value
        Check-Record $record 'staging' $false "billing acknowledgment invalid $($invalid.field)"
    }
    foreach ($amount in @('projectAllowanceUsd', 'reserveUsd', 'currentEstimatedSpendUsd')) {
        $record = New-Evidence 'billing-acknowledgment'; $record[$amount] = 100
        Check-Record $record 'staging' $false "billing acknowledgment cannot silently ignore numeric field $amount"
    }
    $record = New-Evidence 'billing-acknowledgment'; $record.Remove('costAuthorization')
    Check-Record $record 'staging' $false 'acknowledgment requires explicit cost mode'

    Write-Output "Cloud-window contract tests passed ($script:assertions assertions)."
}
finally {
    Remove-Item -LiteralPath $evidenceFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Force
}
