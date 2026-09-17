[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('\A[a-f0-9]{40}\z')][string]$SourceCommit,
    [Parameter(Mandatory)][string]$OutputFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
# Archive the exact committed tree with a fixed timestamp. Merge metadata must
# not change artifact bytes; any content change must change the reviewed digest.
$tree = & git -C $repoRoot rev-parse --verify "$SourceCommit^{tree}" 2>$null
if ($LASTEXITCODE -ne 0 -or $tree -cnotmatch '\A[a-f0-9]{40}\z') { throw 'Reviewed source commit cannot be resolved.' }
& git -C $repoRoot archive --format=zip --mtime=2000-01-01T00:00:00Z "--output=$OutputFile" $tree
if ($LASTEXITCODE -ne 0) { throw 'Deterministic source packaging failed.' }
Write-Output (Get-FileHash -LiteralPath $OutputFile -Algorithm SHA256).Hash.ToLowerInvariant()
