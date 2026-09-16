[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EvidenceFile,

    [string]$NowUtc = ''
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
try {
    $allowance = [decimal](Require $evidence 'projectAllowanceUsd')
    $reserve = [decimal](Require $evidence 'reserveUsd')
    $spent = [decimal](Require $evidence 'currentEstimatedSpendUsd')
}
catch { Fail 'cost evidence must contain decimal USD values.' }

$now = if ([string]::IsNullOrWhiteSpace($NowUtc)) { [datetimeoffset]::UtcNow } else { [datetimeoffset]::Parse($NowUtc).ToUniversalTime() }
if ($windowStart -ge $windowEnd) { Fail 'window start must precede window end.' }
if ($recordedAt -gt $now.AddMinutes(5) -or $recordedAt -lt $now.AddHours(-24)) { Fail 'account evidence must be less than 24 hours old.' }
if ($allowance -le 0 -or $reserve -lt 0 -or $spent -lt 0 -or $reserve -ge $allowance) { Fail 'cost allowance and reserve are invalid.' }
if ($spent -gt ($allowance - $reserve)) { Fail 'current estimated spend exceeds the approved allowance after reserve.' }
if ($now -lt $windowStart -or $now -gt $windowEnd) { Fail 'the approved cloud deployment window is closed.' }

Write-Output 'Cloud deployment window is open.'
