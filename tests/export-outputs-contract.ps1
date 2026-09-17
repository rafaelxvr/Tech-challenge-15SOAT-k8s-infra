[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) ('oficina-export-outputs-' + [guid]::NewGuid())
$fixture = Join-Path $temp 'terraform root with spaces'
New-Item -ItemType Directory -Path $fixture -Force | Out-Null

try {
    # A local, resource-free state exercises the real native Terraform argument
    # boundary without provider installation, remote state, or AWS credentials.
    $allowlist = Get-Content -LiteralPath (Join-Path $repoRoot 'contracts/outputs-allowlist.json') -Raw | ConvertFrom-Json
    $outputs = [ordered]@{}
    foreach ($mapping in $allowlist.scopes.environment.PSObject.Properties) {
        $outputs[$mapping.Value] = @{ value = "fixture-$($mapping.Name)"; type = 'string'; sensitive = $false }
    }
    @{ version = 4; terraform_version = '1.10.0'; serial = 1; lineage = [guid]::NewGuid().ToString(); outputs = $outputs; resources = @() } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $fixture 'terraform.tfstate') -NoNewline
    Push-Location -LiteralPath $temp
    try {
        foreach ($pathKind in @('absolute', 'relative')) {
            $directory = if ($pathKind -eq 'absolute') { $fixture } else { './terraform root with spaces' }
            $published = Join-Path $temp "$pathKind.json"
            & (Join-Path $repoRoot 'scripts/export-outputs.ps1') -TerraformDirectory $directory -Scope environment -Environment staging -SourceCommit ('a' * 40) -OutputFile $published | Out-Null
            $document = Get-Content -LiteralPath $published -Raw | ConvertFrom-Json
            if ($document.schemaVersion -ne 1 -or $document.environment -cne 'staging' -or $document.sourceCommit -cne ('a' * 40)) {
                throw "Export metadata must survive a $pathKind Terraform directory argument."
            }
            foreach ($mapping in $allowlist.scopes.environment.PSObject.Properties) {
                if ($document.outputs.($mapping.Name) -cne "fixture-$($mapping.Name)") {
                    throw "Terraform must read the intended $pathKind directory, with no literal variable or split path leakage."
                }
            }
        }
    }
    finally { Pop-Location }
    $firstOutput = @($outputs.Keys)[0]
    $outputs[$firstOutput].sensitive = $true
    $raw = Join-Path $temp 'sensitive.json'
    $outputs | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $raw
    $rejected = $false
    try { & (Join-Path $repoRoot 'scripts/export-outputs.ps1') -TerraformOutputFile $raw -Scope environment -Environment staging -SourceCommit ('a' * 40) -OutputFile (Join-Path $temp 'blocked.json') | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'An allowlisted field marked sensitive must never be published.' }
    Write-Output 'Output export contract: PASS (real Terraform; absolute and relative directories containing spaces).'
}
finally {
    $resolved = [IO.Path]::GetFullPath($temp)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Path]::GetFileName($resolved).StartsWith('oficina-export-outputs-')) {
        throw 'Refusing cleanup outside the isolated output-export fixture.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
