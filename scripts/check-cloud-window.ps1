[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EvidenceFile,

    [string]$NowUtc = '',

    [ValidateSet('staging', 'production')]
    [string]$Environment = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) { throw "Cloud-window validation failed: $Message" }
function Require([object]$Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or ([string]$property.Value).Trim().Length -eq 0) {
        Fail "evidence is missing '$Name'."
    }
    return $property.Value
}
function Require-String([object]$Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value)) {
        Fail "evidence must contain a non-empty string '$Name'."
    }
    return $property.Value
}
function Parse-UtcTimestamp([object]$Value) {
    if ($Value -is [datetime]) { return [datetimeoffset]$Value.ToUniversalTime() }
    return [datetimeoffset]::Parse([string]$Value).ToUniversalTime()
}

if (-not (Test-Path -LiteralPath $EvidenceFile -PathType Leaf)) { Fail 'evidence file does not exist.' }
try { $evidence = Get-Content -LiteralPath $EvidenceFile -Raw | ConvertFrom-Json }
catch { Fail 'evidence file is not valid JSON.' }

try {
    $windowStart = Parse-UtcTimestamp (Require $evidence 'windowStartUtc')
    $windowEnd = Parse-UtcTimestamp (Require $evidence 'windowEndUtc')
    $recordedAt = Parse-UtcTimestamp (Require $evidence 'recordedAtUtc')
}
catch { Fail 'windowStartUtc, windowEndUtc and recordedAtUtc must be UTC timestamps.' }

$null = Require $evidence 'accountEvidenceReference'
$now = if ([string]::IsNullOrWhiteSpace($NowUtc)) { [datetimeoffset]::UtcNow } else { [datetimeoffset]::Parse($NowUtc).ToUniversalTime() }
if ($windowStart -ge $windowEnd) { Fail 'window start must precede window end.' }
if ($recordedAt -gt $now.AddMinutes(5) -or $recordedAt -lt $now.AddHours(-24)) { Fail 'account evidence must be less than 24 hours old.' }
if ($now -lt $windowStart -or $now -gt $windowEnd) { Fail 'the approved cloud deployment window is closed.' }

$mode = if ($null -eq $evidence.PSObject.Properties['costAuthorization']) { 'numeric-budget' }
        else { Require-String $evidence 'costAuthorization' }
switch -CaseSensitive ($mode) {
    'numeric-budget' {
        try {
            $allowance = [decimal](Require $evidence 'projectAllowanceUsd')
            $reserve = [decimal](Require $evidence 'reserveUsd')
            $spent = [decimal](Require $evidence 'currentEstimatedSpendUsd')
        }
        catch { Fail 'cost evidence must contain decimal USD values.' }
        if ($allowance -le 0 -or $reserve -lt 0 -or $spent -lt 0 -or $reserve -ge $allowance) { Fail 'cost allowance and reserve are invalid.' }
        if ($spent -gt ($allowance - $reserve)) { Fail 'current estimated spend exceeds the approved allowance after reserve.' }
    }
    'billing-acknowledgment' {
        if ($Environment -cne 'staging' -or (Require-String $evidence 'environment') -cne 'staging' -or
            (Require-String $evidence 'scope') -cne 'study-staging') {
            Fail 'billing acknowledgment authorizes only the explicitly targeted study staging rehearsal.'
        }
        $acknowledgment = $evidence.PSObject.Properties['billingBeyondFreeCreditsAcknowledged']
        if ($null -eq $acknowledgment -or $acknowledgment.Value -isnot [bool] -or -not $acknowledgment.Value) {
            Fail 'billingBeyondFreeCreditsAcknowledged must be the JSON boolean true.'
        }
        $null = Require-String $evidence 'approvalReference'
        foreach ($amount in @('projectAllowanceUsd', 'reserveUsd', 'currentEstimatedSpendUsd')) {
            if ($null -ne $evidence.PSObject.Properties[$amount]) {
                Fail 'billing acknowledgment must not mix in numeric-budget fields; select one cost authorization mode.'
            }
        }
    }
    default { Fail 'costAuthorization must be numeric-budget or billing-acknowledgment.' }
}

Write-Output 'Cloud deployment window is open.'
