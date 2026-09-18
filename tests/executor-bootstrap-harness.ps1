[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) { throw "Executor bootstrap harness failed: $Message" }
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { Fail $Message } }
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Write-BashSingleQuoted([string]$Value) {
    if ($Value.Contains("'")) { Fail 'Harness paths must not contain a single quote.' }
    return "'$Value'"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $repoRoot 'infra/modules/deployment-executor'
$runningOnWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
$shell = if ($runningOnWindows) {
    'C:/Program Files/Git/bin/bash.exe'
}
else {
    $bashCommand = @(Get-Command bash -CommandType Application -ErrorAction SilentlyContinue)[0]
    if ($null -eq $bashCommand) { $null } else { $bashCommand.Source }
}
if ([string]::IsNullOrWhiteSpace($shell) -or -not (Test-Path -LiteralPath $shell -PathType Leaf)) {
    Fail $(if ($runningOnWindows) { 'Git Bash is required for the local CodeBuild bootstrap harness.' } else { 'bash is required for the local CodeBuild bootstrap harness.' })
}
$temp = Join-Path ([System.IO.Path]::GetTempPath()) "oficina-executor-harness-$([guid]::NewGuid())"

try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $deployments = @{
        k8s_staging          = @{ repository = 'oficina-k8s-infra'; environment = 'staging'; source_prefix = 'releases/k8s/staging'; terraform_state_key = 'environments/staging.tfstate'; deployment_mode = 'plan'; terraform_variables_path = '/tmp/oficina/k8s_staging.tfvars.json' }
        k8s_production       = @{ repository = 'oficina-k8s-infra'; environment = 'production'; source_prefix = 'releases/k8s/production'; terraform_state_key = 'environments/production.tfstate'; deployment_mode = 'plan'; terraform_variables_path = '/tmp/oficina/k8s_production.tfvars.json' }
        db_staging           = @{ repository = 'oficina-db-infra'; environment = 'staging'; source_prefix = 'releases/database/staging'; terraform_state_key = 'database/staging.tfstate'; deployment_mode = 'plan'; terraform_variables_path = '/tmp/oficina/database_staging.tfvars.json' }
        db_production        = @{ repository = 'oficina-db-infra'; environment = 'production'; source_prefix = 'releases/database/production'; terraform_state_key = 'database/production.tfstate'; deployment_mode = 'plan'; terraform_variables_path = '/tmp/oficina/database_production.tfvars.json' }
        functions_staging    = @{ repository = 'oficina-functions'; environment = 'staging'; source_prefix = 'releases/functions/staging'; terraform_state_key = 'functions/staging.tfstate'; deployment_mode = 'plan'; terraform_variables_path = '/tmp/oficina/functions_staging.tfvars.json' }
        functions_production = @{ repository = 'oficina-functions'; environment = 'production'; source_prefix = 'releases/functions/production'; terraform_state_key = 'functions/production.tfstate'; deployment_mode = 'plan'; terraform_variables_path = '/tmp/oficina/functions_production.tfvars.json' }
        app_staging          = @{ repository = 'oficina-app'; environment = 'staging'; source_prefix = 'releases/app/staging'; terraform_state_key = 'app/staging.tfstate'; deployment_mode = 'plan'; terraform_variables_path = '/tmp/oficina/app_staging.tfvars.json' }
        app_production       = @{ repository = 'oficina-app'; environment = 'production'; source_prefix = 'releases/app/production'; terraform_state_key = 'app/production.tfstate'; deployment_mode = 'plan'; terraform_variables_path = '/tmp/oficina/app_production.tfvars.json' }
    }
    $variables = @{
        name = 'oficina-phase3'; aws_region = 'us-east-1'; account_id = '123456789012'; vpc_id = 'vpc-12345678'
        cluster_arn = 'arn:aws:eks:us-east-1:123456789012:cluster/oficina-phase3'
        node_group_arns = @('arn:aws:eks:us-east-1:123456789012:nodegroup/oficina-phase3/workers-a/example')
        kubernetes_repository = 'oficina-k8s-infra'; artifact_bucket_name = 'oficina-phase3-artifacts-example'; state_bucket_name = 'oficina-phase3-state-example'
        private_subnet_ids = @('subnet-a'); security_group_ids = @('sg-codebuild')
        deployer_image_digest = 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'; deployments = $deployments
    }
    $tfvars = Join-Path $temp 'executor.tfvars.json'
    $variables | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tfvars -NoNewline
    $expression = 'jsonencode(local.rendered_deployment_buildspecs)'
    $renderedJson = $expression | & terraform "-chdir=$moduleRoot" console -no-color "-var-file=$tfvars" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "Terraform could not render the CodeBuild buildspec: $($renderedJson -join [Environment]::NewLine)" }
    $renderedBuildspecs = (($renderedJson -join [Environment]::NewLine) | ConvertFrom-Json) | ConvertFrom-Json
    $prepareTfvarsDirectory = 'mkdir -p "$(dirname "${reviewed_tfvars_path}")"'
    foreach ($rendered in $renderedBuildspecs.PSObject.Properties) {
        $lines = @($rendered.Value -split "`r?`n" | ForEach-Object { $_.Trim() })
        $download = [array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($line) $line.StartsWith('aws s3api get-object') -and $line.Contains('"${TFVARS_OBJECT_KEY}"') })
        Assert-True ($download -gt 0 -and $lines[$download - 1] -ceq $prepareTfvarsDirectory) "$($rendered.Name) must create the reviewed tfvars parent immediately before its versioned download."
    }
    # Exercise the rendered directory-preparation command against a fresh local
    # path containing spaces. The AWS fixture below must never create parents.
    $directoryFixture = Join-Path $temp 'fresh parent with spaces/inputs.tfvars.json'
    $prepareScript = Join-Path $temp 'prepare-tfvars-directory.sh'
    $prepareSource = 'set -euo pipefail' + "`n" + 'reviewed_tfvars_path=' + (Write-BashSingleQuoted $directoryFixture.Replace('\', '/')) + "`n" + $prepareTfvarsDirectory + "`n" + 'test -d "$(dirname "${reviewed_tfvars_path}")"'
    Set-Content -LiteralPath $prepareScript -Value $prepareSource -NoNewline
    & $shell $prepareScript
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Split-Path -Parent $directoryFixture) -PathType Container)) 'Rendered preparation must create a missing parent without losing path quoting.'
    foreach ($environment in @('staging', 'production')) {
        $dbBuildspec = $renderedBuildspecs.PSObject.Properties["db_$environment"].Value
        Assert-True ($deployments["db_$environment"].source_prefix -ceq "releases/database/$environment") "DB $environment source fixture must match the approved database prefix."
        Assert-True ($dbBuildspec.Contains("reviewed_backend_key=`"database/$environment.tfstate`"")) "DB $environment bootstrap must use the approved database state key."
        Assert-True ($dbBuildspec.Contains("reviewed_backend_lock_key=`"database/$environment.tfstate.tflock`"")) "DB $environment bootstrap must use its derived database lock key."
        Assert-True ($dbBuildspec.Contains("reviewed_tfvars_path=`"/tmp/oficina/database_$environment.tfvars.json`"")) "DB $environment bootstrap must use the approved trusted tfvars path."
    }
    $buildspec = $renderedBuildspecs.k8s_staging
    $functionsBuildspec = $renderedBuildspecs.functions_staging
    Assert-True ($buildspec -match 'reviewed_backend_key="environments/staging\.tfstate"') 'Terraform did not render the staging backend key into the CodeBuild buildspec.'
    Assert-True ($functionsBuildspec.Contains('ExpectedTerraformVariablesSha256')) 'The functions executor must pass the downloaded Terraform variables digest to deploy.ps1.'
    Assert-True ($functionsBuildspec.Contains('-StateBucket "${reviewed_backend_bucket}" -SharedFoundationMutation')) 'The functions executor must pass the reviewed shared state bucket and mutation lock switch to deploy.ps1.'
    $functionsLockGuard = 'if [ "${reviewed_repository}" = "oficina-functions" ]; then'
    Assert-True ($functionsBuildspec.Contains($functionsLockGuard)) 'The functions shared foundation lock arguments must be guarded by the reviewed functions repository identity.'
    Assert-True ($functionsBuildspec.IndexOf('-StateBucket "${reviewed_backend_bucket}" -SharedFoundationMutation') -gt $functionsBuildspec.IndexOf($functionsLockGuard)) 'The functions shared foundation lock arguments must be assigned inside the functions-only guard.'
    Assert-True ($buildspec.Contains('reviewed_repository="oficina-k8s-infra"')) 'The Kubernetes executor must render its repository identity for the functions-only digest gate.'

    $buildspecLines = $buildspec -split "`r?`n"
    $start = [array]::FindIndex([string[]]$buildspecLines, [Predicate[string]]{ param($line) $line -match '^\s+set -euo pipefail$' })
    if ($start -lt 0) { Fail 'Rendered CodeBuild buildspec has no shell command block.' }
    $bootstrap = (@($buildspecLines[$start..($buildspecLines.Length - 1)] | ForEach-Object { $_ -replace '^\s{12}', '' }) -join "`n")
    $bootstrapPath = Join-Path $temp 'rendered-bootstrap.sh'
    Set-Content -LiteralPath $bootstrapPath -NoNewline -Value $bootstrap

    $bundleRoot = Join-Path $temp 'bundle-root'
    New-Item -ItemType Directory -Path $bundleRoot | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $bundleRoot 'scripts') | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/deploy.ps1') -Destination (Join-Path $bundleRoot 'scripts/deploy.ps1')
    # deploy.ps1 only needs this root to exist before the harness Terraform
    # stub captures init/validate/plan; copying provider caches is unnecessary.
    New-Item -ItemType Directory -Path (Join-Path $bundleRoot 'infra/environments/staging') -Force | Out-Null
    $bundle = Join-Path $temp 'bundle.zip'
    Compress-Archive -Path (Join-Path $bundleRoot '*') -DestinationPath $bundle
    $sourceSha = Hash $bundle
    $manifest = Join-Path $temp 'release-manifest.json'
    @{ schemaVersion = 1; environment = 'staging'; sourceCommit = ('a' * 40); artifactSha256 = $sourceSha; deployerImageDigest = ('sha256:' + ('b' * 64)); contractVersion = 'phase3-v2'; migrationVersion = 'platform-v1'; promotedFromStaging = $false } | ConvertTo-Json | Set-Content -LiteralPath $manifest -NoNewline
    $manifestSha = Hash $manifest
    $tfvarsInput = Join-Path $temp 'terraform.tfvars.json'; '{}' | Set-Content -LiteralPath $tfvarsInput -NoNewline
    $tfvarsSha = Hash $tfvarsInput

    $bin = Join-Path $temp 'bin'; New-Item -ItemType Directory -Path $bin | Out-Null
    $awsStub = @'
#!/usr/bin/env bash
set -euo pipefail
key=""
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "--key" ]; then j=$((i+1)); key="${!j}"; fi
done
destination="${!#}"
case "$key" in
  "$SOURCE_KEY") source="$HARNESS_BUNDLE" ;;
  "$RELEASE_MANIFEST_KEY") source="$HARNESS_MANIFEST" ;;
  "$TFVARS_OBJECT_KEY") source="$HARNESS_TFVARS" ;;
  *) echo "unexpected mock S3 key: $key" >&2; exit 64 ;;
esac
test -d "$(dirname "$destination")" || { echo 'Download destination parent is missing.' >&2; exit 65; }
cp "$source" "$destination"
'@
    Set-Content -LiteralPath (Join-Path $bin 'aws') -NoNewline -Value $awsStub
    $pwshStub = @'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$PWSH_CAPTURE_FILE"
exec "$(cygpath -u "$HARNESS_REAL_PWSH")" "$@"
'@
    if (-not $runningOnWindows) {
        $pwshStub = $pwshStub.Replace('exec "$(cygpath -u "$HARNESS_REAL_PWSH")" "$@"', 'exec "$HARNESS_REAL_PWSH" "$@"')
    }
    Set-Content -LiteralPath (Join-Path $bin 'pwsh') -NoNewline -Value $pwshStub
    $terraformStub = if ($runningOnWindows) { @'
@echo off
echo %*>> "%CAPTURE_FILE%"
exit /b 0
'@ } else { @'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CAPTURE_FILE"
'@ }
    $terraformStubName = if ($runningOnWindows) { 'terraform.cmd' } else { 'terraform' }
    Set-Content -LiteralPath (Join-Path $bin $terraformStubName) -NoNewline -Value $terraformStub
    if (-not $runningOnWindows) {
        foreach ($stub in @('aws', 'pwsh', $terraformStubName)) {
            & chmod +x (Join-Path $bin $stub)
            if ($LASTEXITCODE -ne 0) { Fail "Could not mark the Linux harness stub '$stub' executable." }
        }
    }
    $capture = Join-Path $temp 'terraform-capture.txt'
    $pwshCapture = Join-Path $temp 'pwsh-capture.txt'
    $scriptPath = $bootstrapPath.Replace('\', '/')
    $binPath = $bin.Replace('\', '/')
    $script = if ($runningOnWindows) {
        'export PATH="$(cygpath -u ' + (Write-BashSingleQuoted $binPath) + '):$PATH"' + "`n" + 'exec /usr/bin/bash "$(cygpath -u ' + (Write-BashSingleQuoted $scriptPath) + ')"' + "`n"
    }
    else {
        'export PATH=' + (Write-BashSingleQuoted $binPath) + ':$PATH' + "`n" + 'exec ' + (Write-BashSingleQuoted $shell) + ' ' + (Write-BashSingleQuoted $scriptPath) + "`n"
    }
    $runner = Join-Path $temp 'run-rendered-bootstrap.sh'; Set-Content -LiteralPath $runner -NoNewline -Value $script

    $overrideNames = @('DEPLOY_ENVIRONMENT', 'TERRAFORM_BACKEND_BUCKET', 'TERRAFORM_BACKEND_KEY', 'TERRAFORM_BACKEND_LOCK_KEY', 'TERRAFORM_BACKEND_REGION', 'SOURCE_BUCKET', 'SOURCE_KEY', 'SOURCE_VERSION_ID', 'EXPECTED_SHA256', 'RELEASE_MANIFEST_KEY', 'RELEASE_MANIFEST_VERSION_ID', 'EXPECTED_MANIFEST_SHA256', 'SOURCE_COMMIT', 'DEPLOYER_IMAGE_DIGEST', 'DEPLOYMENT_TFVARS_PATH', 'DEPLOYMENT_MODE', 'TFVARS_OBJECT_KEY', 'TFVARS_VERSION_ID', 'EXPECTED_TFVARS_SHA256', 'HARNESS_BUNDLE', 'HARNESS_MANIFEST', 'HARNESS_TFVARS', 'CAPTURE_FILE', 'PWSH_CAPTURE_FILE', 'HARNESS_REAL_PWSH')
    $original = @{}
    foreach ($name in $overrideNames) { $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        $env:DEPLOY_ENVIRONMENT = 'staging'; $env:TERRAFORM_BACKEND_BUCKET = 'attacker-state-example'; $env:TERRAFORM_BACKEND_KEY = 'environments/production.tfstate'; $env:TERRAFORM_BACKEND_LOCK_KEY = 'environments/production.tfstate.tflock'; $env:TERRAFORM_BACKEND_REGION = 'eu-west-1'
        $env:SOURCE_BUCKET = 'harness-artifacts'; $env:SOURCE_KEY = 'releases/k8s/staging/bundle.zip'; $env:SOURCE_VERSION_ID = 'bundle-version'; $env:EXPECTED_SHA256 = $sourceSha
        $env:RELEASE_MANIFEST_KEY = ('releases/k8s/staging/manifests/' + ('a' * 40) + '.json'); $env:RELEASE_MANIFEST_VERSION_ID = 'manifest-version'; $env:EXPECTED_MANIFEST_SHA256 = $manifestSha
        $env:SOURCE_COMMIT = ('a' * 40); $env:DEPLOYER_IMAGE_DIGEST = ('sha256:' + ('b' * 64)); $env:DEPLOYMENT_TFVARS_PATH = '/tmp/attacker.tfvars.json'; $env:DEPLOYMENT_MODE = 'apply'
        $env:TFVARS_OBJECT_KEY = 'releases/k8s/staging/config/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.tfvars.json'; $env:TFVARS_VERSION_ID = 'tfvars-version'; $env:EXPECTED_TFVARS_SHA256 = $tfvarsSha
        $env:HARNESS_BUNDLE = $bundle; $env:HARNESS_MANIFEST = $manifest; $env:HARNESS_TFVARS = $tfvarsInput; $env:CAPTURE_FILE = $capture; $env:PWSH_CAPTURE_FILE = $pwshCapture; $env:HARNESS_REAL_PWSH = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        & $shell $runner
        Assert-True ($LASTEXITCODE -eq 0) 'The rendered bootstrap did not complete with attacker backend overrides present.'
        $terraformCalls = Get-Content -LiteralPath $capture -Raw
        $pwshCalls = Get-Content -LiteralPath $pwshCapture -Raw
        Assert-True ($terraformCalls -match 'init.*-backend-config=bucket=oficina-phase3-state-example.*-backend-config=key=environments/staging.tfstate.*-backend-config=region=us-east-1') 'The rendered bootstrap did not pass its literal reviewed backend arguments through deploy.ps1 to terraform init.'
        Assert-True ($pwshCalls -match '-TerraformVariablesFile /tmp/oficina/k8s_staging\.tfvars\.json') 'The rendered bootstrap did not pass its literal reviewed tfvars path through deploy.ps1.'
        Assert-True ($pwshCalls -notmatch 'ExpectedTerraformVariablesSha256|StateBucket|SharedFoundationMutation') 'Kubernetes bootstrap must not receive functions-only Terraform digest or shared lock arguments.'
        Assert-True ($pwshCalls -notmatch 'attacker\.tfvars\.json' -and $pwshCalls -notmatch 'ApplyReviewedPlan' -and $terraformCalls -notmatch 'apply') 'StartBuild mode and tfvars overrides must not reach deploy or Terraform apply.'

        Remove-Item -LiteralPath $capture -Force
        $env:DEPLOY_ENVIRONMENT = 'production'
        & $shell $runner 2>$null
        Assert-True ($LASTEXITCODE -ne 0) 'A mismatched DEPLOY_ENVIRONMENT override must fail in the rendered bootstrap.'
        Assert-True (-not (Test-Path -LiteralPath $capture -PathType Leaf)) 'A mismatched DEPLOY_ENVIRONMENT override reached Terraform.'
    }
    finally {
        foreach ($name in $overrideNames) {
            if ($null -eq $original[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            else { Set-Item -LiteralPath "Env:$name" -Value $original[$name] }
        }
    }
    Write-Output 'PASS: Terraform-rendered CodeBuild bootstrap ignores backend/mode/tfvars StartBuild overrides and rejects mismatched environments before Terraform.'
    exit 0
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
