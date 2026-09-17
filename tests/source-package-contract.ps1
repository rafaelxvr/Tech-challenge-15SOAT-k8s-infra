[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) ('oficina-package-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path "$temp/scripts" -Force | Out-Null
try {
    Copy-Item -LiteralPath "$repo/scripts/package-source.ps1" -Destination "$temp/scripts/package-source.ps1"
    & git -C $temp init -q
    'same reviewed content' | Set-Content -LiteralPath "$temp/content.txt"
    & git -C $temp add -- content.txt
    & git -C $temp -c user.name=fixture -c user.email=fixture@example.invalid commit -qm first
    $first = & git -C $temp rev-parse HEAD
    & git -C $temp -c user.name=fixture -c user.email=fixture@example.invalid commit --allow-empty -qm merge-metadata
    $second = & git -C $temp rev-parse HEAD
    $one = & "$temp/scripts/package-source.ps1" -SourceCommit $first -OutputFile "$temp/one.zip"
    $two = & "$temp/scripts/package-source.ps1" -SourceCommit $second -OutputFile "$temp/two.zip"
    if ($first -ceq $second -or $one -cne $two) { throw 'Identical trees at different commits must produce identical artifacts.' }
    'changed content' | Set-Content -LiteralPath "$temp/content.txt"
    & git -C $temp add -- content.txt
    & git -C $temp -c user.name=fixture -c user.email=fixture@example.invalid commit -qm changed
    $third = & git -C $temp rev-parse HEAD
    $three = & "$temp/scripts/package-source.ps1" -SourceCommit $third -OutputFile "$temp/three.zip"
    if ($three -ceq $two) { throw 'Content-changing promotion must require a new staging artifact.' }
    $rejected = $false
    try { & "$temp/scripts/package-source.ps1" -SourceCommit ('0' * 40) -OutputFile "$temp/missing.zip" | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'An unavailable source commit must fail closed.' }
    Write-Output 'PASS: deterministic archive promotion rejects changed trees and unknown commits.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($temp)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($resolved).StartsWith('oficina-package-')) { throw 'Unsafe cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
