[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Acquire', 'Release')]
    [string]$Action,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$')]
    [string]$StateBucket,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-f0-9-]{36}$')]
    [string]$OwnerToken,

    [ValidatePattern('^deployment-locks/[a-z0-9._/-]+\.json$')]
    [string]$Key = 'deployment-locks/shared-foundation.json',

    [switch]$Offline,
    [string]$OfflineDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) { throw "Deployment lock failed: $Message" }
function Get-OfflinePath {
    if ([string]::IsNullOrWhiteSpace($OfflineDirectory)) { Fail 'OfflineDirectory is required for offline lock verification.' }
    if (-not (Test-Path -LiteralPath $OfflineDirectory -PathType Container)) { New-Item -ItemType Directory -Path $OfflineDirectory -Force | Out-Null }
    return Join-Path $OfflineDirectory (($Key -replace '[\\/]', '__'))
}
function Acquire-Offline {
    $path = Get-OfflinePath
    try {
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $writer = $null
        try { $writer = [System.IO.StreamWriter]::new($stream); $writer.Write($OwnerToken); $writer.Flush() }
        finally { if ($null -ne $writer) { $writer.Dispose() } else { $stream.Dispose() } }
    }
    catch [System.IO.IOException] { Fail 'a shared deployment lock is already active; it was not replaced.' }
}
function Release-Offline {
    $path = Get-OfflinePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail 'shared deployment lock does not exist.' }
    if ((Get-Content -LiteralPath $path -Raw).Trim() -cne $OwnerToken) { Fail 'lock owner mismatch; an active lock was not removed.' }
    Remove-Item -LiteralPath $path -Force
}

if ($Offline) {
    # Serialize the offline read/compare/delete and acquisition across processes.
    # No guard file is deleted/recreated, so a successor cannot bypass the guard.
    $lockPath = [System.IO.Path]::GetFullPath((Get-OfflinePath))
    if ($IsWindows) { $lockPath = $lockPath.ToUpperInvariant() }
    $pathHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($lockPath)))
    $mutex = [System.Threading.Mutex]::new($false, "oficina-deployment-lock-$pathHash")
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
        if (-not $acquired) { Fail 'a concurrent offline lock operation is active.' }
        if ($Action -eq 'Acquire') { Acquire-Offline } else { Release-Offline }
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    Write-Output "Shared deployment lock $Action succeeded."
    exit 0
}

$payload = Join-Path ([System.IO.Path]::GetTempPath()) "oficina-lock-$OwnerToken.json"
try {
    if ($Action -eq 'Acquire') {
        @{ ownerToken = $OwnerToken; acquiredAtUtc = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress | Set-Content -LiteralPath $payload -NoNewline
        & aws s3api put-object --bucket $StateBucket --key $Key --body $payload --if-none-match '*' --metadata "owner=$OwnerToken" --output json 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail 'a shared deployment lock is already active; it was not replaced.' }
    }
    else {
        $head = & aws s3api head-object --bucket $StateBucket --key $Key --output json 2>$null
        if ($LASTEXITCODE -ne 0) { Fail 'shared deployment lock does not exist.' }
        $metadata = $head | ConvertFrom-Json
        if ($metadata.Metadata.owner -cne $OwnerToken) { Fail 'lock owner mismatch; an active lock was not removed.' }
        $etag = $metadata.PSObject.Properties['ETag']
        if ($null -eq $etag -or $etag.Value -isnot [string] -or $etag.Value -cnotmatch '\A"[^"*\r\n]+"\z') { Fail 'lock lookup did not return an exact ETag; release was not attempted.' }
        # Owner metadata and ETag come from the same HEAD. The payload contains
        # its unique owner token, so a successor has different bytes and ETag.
        # S3 compares atomically; never retry without this condition on 412/409.
        & aws s3api delete-object --bucket $StateBucket --key $Key --if-match $etag.Value --output json 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail 'conditional lock release failed; a replacement lock was not removed.' }
    }
}
finally {
    Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue
}

Write-Output "Shared deployment lock $Action succeeded."
