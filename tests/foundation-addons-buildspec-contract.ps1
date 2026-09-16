[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/modules/foundation-addons-executor/main.tf') -Raw
$template = [regex]::Match($source, '(?ms)^\s*buildspec\s*=\s*<<-YAML\r?\n(?<body>.*?)^\s*YAML\s*$')
if (-not $template.Success) { throw 'Foundation-addons buildspec heredoc was not found.' }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('oficina-addons-buildspec-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null

try {
    # Real Terraform interpolation/YAML decoding, with no providers or backend:
    # this fixture needs neither init nor AWS access and never changes a repo lockfile.
    $template.Groups['body'].Value -replace '(?m)^    ', '' | Set-Content -LiteralPath (Join-Path $temp 'buildspec.tftpl') -NoNewline
    @'
locals {
  buildspec = templatefile("${path.module}/buildspec.tftpl", {
    local = {
      generated_tfvars = jsonencode({ aws_region = "us-east-1", cluster_name = "oficina-test" })
      state_key = "foundation-addons/terraform.tfstate"
    }
    var = { state_bucket_name = "oficina-state-test", aws_region = "us-east-1" }
  })
}
'@ | Set-Content -LiteralPath (Join-Path $temp 'main.tf')
    $output = 'jsonencode(yamldecode(local.buildspec))' | & terraform "-chdir=$temp" console -no-color 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Rendered foundation-addons buildspec must parse as YAML: $($output -join [Environment]::NewLine)" }
    $document = (($output -join [Environment]::NewLine) | ConvertFrom-Json) | ConvertFrom-Json
    if ($document.version -ne 0.2) { throw 'The buildspec must retain CodeBuild version 0.2.' }
    $commands = @($document.phases.build.commands)
    for ($index = 0; $index -lt $commands.Count; $index++) {
        if ($commands[$index] -isnot [string] -or [string]::IsNullOrWhiteSpace($commands[$index])) {
            throw "Buildspec Commands[$index] must be a non-empty YAML string, not a mapping or another value."
        }
        if ($commands[$index].Contains('$$(')) {
            throw "Buildspec Commands[$index] contains a literal doubled-dollar command substitution; Bash would expand its PID."
        }
    }
    if ($commands.Count -ne 17 -or -not $commands[2].Contains('Missing reviewed addon input: ${variable}')) {
        throw 'The rendered input-validation command or command sequence changed unexpectedly.'
    }
    $gitBash = 'C:/Program Files/Git/bin/bash.exe'
    if (-not (Test-Path -LiteralPath $gitBash -PathType Leaf)) { throw 'Git Bash is required for the offline buildspec shell fixture.' }
    $bundle = Join-Path $temp 'input-bundle.zip'
    $manifest = Join-Path $temp 'input-manifest.json'
    'fixture bundle' | Set-Content -LiteralPath $bundle -NoNewline
    '{"fixture":true}' | Set-Content -LiteralPath $manifest -NoNewline
    $bundleSha = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestSha = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
    # Execute the actual rendered assignment and both checksum commands. Leave
    # cleanup to this harness's bounded finally block, not the deployment trap.
    $assignment = ($commands[3] -split ';', 2)[0]
    $runner = Join-Path $temp 'command-substitutions.sh'
    $shell = @(
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'fixture_root="$(cygpath -u "$1")"',
        'export TMPDIR="$fixture_root"',
        'ADDONS_EXPECTED_SHA256="$2"',
        'ADDONS_EXPECTED_MANIFEST_SHA256="$3"',
        $assignment,
        'test -d "$workdir"',
        'case "$workdir" in "$fixture_root/"*) ;; *) exit 90 ;; esac',
        'cp "$fixture_root/input-bundle.zip" "$workdir/bundle.zip"',
        'cp "$fixture_root/input-manifest.json" "$workdir/manifest.json"',
        $commands[5],
        $commands[7]
    ) -join "`n"
    ($shell -replace "`r", '') | Set-Content -LiteralPath $runner -NoNewline
    & $gitBash -n $runner
    if ($LASTEXITCODE -ne 0) { throw 'The rendered command substitutions must be valid Bash.' }
    & $gitBash $runner $temp $bundleSha $manifestSha
    if ($LASTEXITCODE -ne 0) { throw 'Rendered commands must create a real temporary directory and accept matching fixture hashes.' }
    & $gitBash $runner $temp ('0' * 64) $manifestSha
    if ($LASTEXITCODE -eq 0) { throw 'The rendered source checksum must reject a mismatched hash.' }
    & $gitBash $runner $temp $bundleSha ('0' * 64)
    if ($LASTEXITCODE -eq 0) { throw 'The rendered manifest checksum must reject a mismatched hash.' }
    Write-Output "Foundation-addons rendered buildspec contract: PASS ($($commands.Count) string commands; workdir and both checksum substitutions executed)."
    exit 0
}
finally {
    $resolved = [IO.Path]::GetFullPath($temp)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Path]::GetFileName($resolved).StartsWith('oficina-addons-buildspec-')) {
        throw 'Refusing to remove files outside the isolated buildspec test directory.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
