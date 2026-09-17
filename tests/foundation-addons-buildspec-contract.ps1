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
    if ($commands.Count -ne 1 -or -not $commands[0].Contains('Missing reviewed addon input: ${variable}')) {
        throw 'The workdir, downloads, verification, Terraform and EXIT cleanup must share one CodeBuild command shell.'
    }
    $runningOnWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    $shell = if ($runningOnWindows) {
        'C:/Program Files/Git/bin/bash.exe'
    }
    else {
        $bashCommand = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue
        if ($null -eq $bashCommand) { $null } else { $bashCommand.Source }
    }
    if ([string]::IsNullOrWhiteSpace($shell) -or -not (Test-Path -LiteralPath $shell -PathType Leaf)) {
        throw $(if ($runningOnWindows) { 'Git Bash is required for the offline buildspec shell fixture.' } else { 'bash is required for the offline buildspec shell fixture.' })
    }
    # Execute the whole rendered command, including its EXIT trap. Cloud and
    # archive/Terraform operations are stubs; hashes and manifest checks are real.
    $harness = @'
#!/usr/bin/env bash
set -euo pipefail
fixture_root="$(cygpath -u "$1")"
export TMPDIR="$fixture_root"
export ADDONS_EXPECTED_SHA256="$2" ADDONS_EXPECTED_MANIFEST_SHA256="$3"
mode="$4"
real_pwsh="$(cygpath -u "$5")"
export ADDONS_SOURCE_BUCKET=fixture ADDONS_SOURCE_KEY=bundle.zip ADDONS_SOURCE_VERSION_ID=bundle-v
export ADDONS_MANIFEST_KEY=manifest.json ADDONS_MANIFEST_VERSION_ID=manifest-v
export ADDONS_SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
aws() {
  test -d "$workdir"
  local key destination="${!#}"
  while (($#)); do
    if [[ "$1" == --key ]]; then key="$2"; break; fi
    shift
  done
  printf 'download:%s\n' "$key" >> "$fixture_root/trace"
  cp "$fixture_root/input-$key" "$destination"
}
pwsh() {
  printf 'manifest\n' >> "$fixture_root/trace"
  WORKDIR="$(cygpath -w "$workdir")" command "$real_pwsh" "$@"
}
unzip() {
  test -d "$workdir"
  printf 'unzip\n' >> "$fixture_root/trace"
  mkdir -p "$workdir/release/infra/foundation-addons"
  touch "$workdir/release/infra/foundation-addons/main.tf"
}
terraform() {
  test -d "$workdir"
  test -f foundation-addons.auto.tfvars.json
  printf 'terraform:%s\n' "$1" >> "$fixture_root/trace"
  cp foundation-addons.auto.tfvars.json "$fixture_root/generated-tfvars.json"
  if [[ "$1" == plan ]]; then touch foundation-addons.tfplan; fi
  if [[ "$1" == apply ]]; then
    test -f foundation-addons.tfplan
    if [[ "$mode" == apply-failure ]]; then return 52; fi
  fi
}
rm() {
  # The real deployment trap is exercised only within a resolved fixture child.
  test "$#" -eq 2 && test "$1" = -rf || return 90
  local target root
  target="$(realpath -m "$2")"
  root="$(realpath -m "$fixture_root")"
  test "$(dirname "$target")" = "$root" || return 91
  case "$(basename "$target")" in tmp.*) ;; *) return 92 ;; esac
  test -d "$target" || return 93
  printf 'cleanup\n' >> "$fixture_root/trace"
  command rm -rf -- "$target"
}
'@
    if (-not $runningOnWindows) {
        $harness = $harness.Replace('fixture_root="$(cygpath -u "$1")"', 'fixture_root="$1"')
        $harness = $harness.Replace('real_pwsh="$(cygpath -u "$5")"', 'real_pwsh="$5"')
        $harness = $harness.Replace('WORKDIR="$(cygpath -w "$workdir")" command "$real_pwsh" "$@"', 'WORKDIR="$workdir" command "$real_pwsh" "$@"')
    }
    $runner = Join-Path $temp 'build-lifecycle.sh'
    (($harness + "`n" + $commands[0]) -replace "`r", '') | Set-Content -LiteralPath $runner -NoNewline
    & $shell -n $runner
    if ($LASTEXITCODE -ne 0) { throw 'The rendered build block must be valid Bash, including its tfvars heredoc.' }
    $realPwsh = (Get-Command pwsh -CommandType Application).Source
    $allStages = @('download:bundle.zip', 'download:manifest.json', 'manifest', 'unzip', 'terraform:init', 'terraform:validate', 'terraform:plan', 'terraform:apply', 'cleanup')
    foreach ($scenario in @('success', 'bundle-mismatch', 'manifest-mismatch', 'source-mismatch', 'apply-failure')) {
        $fixture = Join-Path $temp $scenario
        New-Item -ItemType Directory -Path $fixture | Out-Null
        $bundle = Join-Path $fixture 'input-bundle.zip'
        $manifest = Join-Path $fixture 'input-manifest.json'
        'fixture bundle' | Set-Content -LiteralPath $bundle -NoNewline
        $bundleSha = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant()
        $sourceCommit = if ($scenario -eq 'source-mismatch') { 'b' * 40 } else { 'a' * 40 }
        @{ schemaVersion = 1; sourceCommit = $sourceCommit; artifactSha256 = $bundleSha } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $manifest -NoNewline
        $manifestSha = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedBundle = if ($scenario -eq 'bundle-mismatch') { '0' * 64 } else { $bundleSha }
        $expectedManifest = if ($scenario -eq 'manifest-mismatch') { '0' * 64 } else { $manifestSha }
        $runOutput = & $shell $runner $fixture $expectedBundle $expectedManifest $scenario $realPwsh 2>&1
        $runExit = $LASTEXITCODE
        if (($scenario -eq 'success' -and $runExit -ne 0) -or ($scenario -ne 'success' -and $runExit -eq 0)) {
            throw "Unexpected lifecycle result for ${scenario}: exit $runExit; $($runOutput -join [Environment]::NewLine)"
        }
        $expectedStages = switch ($scenario) {
            'bundle-mismatch' { @('download:bundle.zip', 'cleanup') }
            'manifest-mismatch' { @('download:bundle.zip', 'download:manifest.json', 'cleanup') }
            'source-mismatch' { @('download:bundle.zip', 'download:manifest.json', 'manifest', 'cleanup') }
            default { $allStages }
        }
        $trace = @(Get-Content -LiteralPath (Join-Path $fixture 'trace'))
        if (($trace -join ',') -cne ($expectedStages -join ',')) {
            throw "Workdir lifecycle must stop at the failing stage and clean up last for ${scenario}: $($trace -join ',')"
        }
        if (@(Get-ChildItem -LiteralPath $fixture -Directory -Filter 'tmp.*').Count -ne 0) {
            throw "The EXIT trap must clean up the workdir for $scenario."
        }
        if ($scenario -eq 'success') {
            $tfvars = Get-Content -LiteralPath (Join-Path $fixture 'generated-tfvars.json') -Raw | ConvertFrom-Json
            if ($tfvars.cluster_name -cne 'oficina-test' -or $tfvars.aws_region -cne 'us-east-1') {
                throw 'The rendered tfvars heredoc must preserve the configured values.'
            }
        }
    }
    Write-Output 'Foundation-addons rendered buildspec contract: PASS (one shell; five lifecycle/hash/manifest scenarios; cleanup after final use and failures).'
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
