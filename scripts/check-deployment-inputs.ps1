[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InputFile,

    # Used only by offline contract tests. Normal execution always asks STS for the current caller ARN.
    [string]$CallerArnForTest,

    # Narrow, user-authorized study exception. It is never valid for production.
    [switch]$AllowStudyRoot,

    [string]$StudyRootJustification = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    throw "Deployment input validation failed: $Message"
}

function Require-Property([object]$Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or ($property.Value -is [string] -and [string]::IsNullOrWhiteSpace($property.Value))) {
        Fail "required property '$Name' is missing."
    }
    return $property.Value
}

function ConvertTo-ReviewedIdentityArn([string]$Arn) {
    # STS returns arn:aws:sts::<account>:assumed-role/<role-name>/<session> for a role session.
    # Normalize that durable role identity before comparing it to the reviewed IAM role ARN.
    if ($Arn -match '^arn:aws:sts::(?<account>[0-9]{12}):assumed-role/(?<role>.+)/[^/]+$') {
        return "arn:aws:iam::$($Matches.account):role/$($Matches.role)"
    }
    return $Arn
}

function Resolve-AwsCliPath {
    $override = [string]$env:OFICINA_AWS_CLI_PATH
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if (-not (Test-Path -LiteralPath $override -PathType Leaf)) { Fail 'OFICINA_AWS_CLI_PATH does not resolve to an AWS CLI executable.' }
        return (Resolve-Path -LiteralPath $override).Path
    }

    $pathCommand = Get-Command aws -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $pathCommand) {
        $commandPath = [string]$pathCommand.Path
        if ([string]::IsNullOrWhiteSpace($commandPath)) { $commandPath = [string]$pathCommand.Source }
        if (-not [string]::IsNullOrWhiteSpace($commandPath)) { return $commandPath }
    }

    $windowsAwsCli = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
    if (Test-Path -LiteralPath $windowsAwsCli -PathType Leaf) { return $windowsAwsCli }

    Fail 'AWS CLI was not found. Install AWS CLI v2, add aws to PATH, or set OFICINA_AWS_CLI_PATH to its local executable.'
}

function Get-CurrentCallerArnFromSts {
    $awsCli = Resolve-AwsCliPath
    # Capture only the configured query output. Do not print CLI diagnostics, credentials, or account metadata.
    $output = @(& $awsCli sts get-caller-identity --query Arn --output text 2>$null)
    $exitCode = $LASTEXITCODE
    $callerArn = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($callerArn)) {
        Fail 'unable to verify the current AWS caller through STS.'
    }
    return $callerArn
}

function Get-Sha256Hex([string]$Value) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    return ([System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function Get-StudyRootJustification([string]$RawJustification) {
    if ([string]::IsNullOrWhiteSpace($RawJustification)) { Fail 'study-root exception requires a nonempty structured justification.' }
    try { $justification = $RawJustification | ConvertFrom-Json -DateKind String } catch { Fail 'study-root justification must be valid JSON.' }
    foreach ($field in @('studyScope', 'operatorApprovedPurpose', 'boundedWindowReference')) {
        $value = [string](Require-Property $justification $field)
        if ([string]::IsNullOrWhiteSpace($value)) { Fail "study-root justification field '$field' is empty." }
    }
    $scope = [string]$justification.studyScope
    $purpose = [string]$justification.operatorApprovedPurpose
    $window = [string]$justification.boundedWindowReference
    if ($scope -notmatch '^phase-3-staging-[a-z0-9-]{3,64}$') { Fail 'study-root justification studyScope must identify a bounded Phase 3 staging study.' }
    if ($purpose.Length -lt 24 -or $purpose -notmatch '(?i)(validate|rehearse|verify)') { Fail 'study-root justification operatorApprovedPurpose is too vague.' }
    if ($window -notmatch '^window-[A-Za-z0-9._-]{6,120}$') { Fail 'study-root justification boundedWindowReference is invalid.' }
    if ($RawJustification -match '(?i)(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|secret|password|credential|token|private.?key|account.?id|arn:aws|\b\d{12}\b)') { Fail 'study-root justification must not contain credential, account, or identity-like content.' }
    return [pscustomobject]@{ Scope = $scope; Purpose = $purpose; Window = $window; Fingerprint = Get-Sha256Hex $RawJustification }
}

function Assert-StudyRootEvidence([object]$Inputs, [object]$Justification, [string]$InputPath) {
    $exception = Require-Property $Inputs 'studyRootException'
    $evidenceReference = [string](Require-Property $exception 'evidenceRecord')
    if ($evidenceReference -notmatch '^[A-Za-z0-9._-]{8,128}\.json$') { Fail 'study-root evidenceRecord must be a local redacted JSON filename.' }
    $inputDirectory = Split-Path -Parent (Resolve-Path -LiteralPath $InputPath)
    $evidencePath = Join-Path $inputDirectory $evidenceReference
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) { Fail 'study-root evidenceRecord does not resolve to a local file beside the input.' }
    try { $evidenceRaw = Get-Content -LiteralPath $evidencePath -Raw; $evidence = $evidenceRaw | ConvertFrom-Json -DateKind String } catch { Fail 'study-root evidenceRecord is not valid JSON.' }
    if ($evidenceRaw -match '(?i)(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|secret|password|credential|token|private.?key|account.?id|arn:aws|\b\d{12}\b)') { Fail 'study-root evidenceRecord must be redacted and contain no credential, account, or identity-like content.' }
    if ([string](Require-Property $evidence 'status') -ne 'APPROVED_FOR_STUDY_STAGING') { Fail 'study-root evidenceRecord must be approved for study staging.' }
    if ([string](Require-Property $evidence 'environment') -ne 'staging') { Fail 'study-root evidenceRecord must be for staging.' }
    $timestamp = [string](Require-Property $evidence 'timestampUtc')
    if ($timestamp -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$') { Fail 'study-root evidenceRecord timestampUtc must be UTC ISO-8601 with Z suffix.' }
    $parsedTimestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($timestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsedTimestamp)) { Fail 'study-root evidenceRecord timestampUtc is invalid.' }
    if ([string](Require-Property $evidence 'justificationFingerprint') -ne $Justification.Fingerprint) { Fail 'study-root evidenceRecord justification fingerprint does not match this invocation.' }
    if ([string](Require-Property $evidence 'studyScope') -ne $Justification.Scope -or [string](Require-Property $evidence 'boundedWindowReference') -ne $Justification.Window) { Fail 'study-root evidenceRecord scope or bounded window does not match this invocation.' }
}

if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
    Fail "input file does not exist."
}

try {
    $inputs = Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json
}
catch {
    Fail "input file is not valid JSON."
}

$accountId = [string](Require-Property $inputs 'accountId')
$region = [string](Require-Property $inputs 'region')
$operatorArn = [string](Require-Property $inputs 'operatorArn')
$oidcArn = [string](Require-Property $inputs 'githubOidcProviderArn')
$stateBucket = [string](Require-Property $inputs 'stateBucketName')
$artifactBucket = [string](Require-Property $inputs 'artifactBucketName')
$launchers = Require-Property $inputs 'launchers'

if ($accountId -notmatch '^[0-9]{12}$') { Fail 'accountId must be a 12-digit AWS account ID.' }
if ($region -ne 'us-east-1') { Fail 'region must be us-east-1 for the approved Phase 3 topology.' }
$operatorIsRoot = $operatorArn -match "^arn:aws:iam::${accountId}:root$"
if ($operatorArn -match ':root$' -and -not $operatorIsRoot) { Fail 'operatorArn root identity must belong to accountId.' }
if ($operatorIsRoot -and -not $AllowStudyRoot) { Fail 'operatorArn cannot be the AWS account root identity without the explicit staging study exception.' }
if (-not $operatorIsRoot -and $operatorArn -notmatch "^arn:aws:iam::${accountId}:(user|role)/.+$") { Fail 'operatorArn must be a user or role in accountId.' }
if ($AllowStudyRoot -and -not $operatorIsRoot) { Fail 'AllowStudyRoot is valid only when operatorArn is the account root identity.' }
if ($oidcArn -notmatch "^arn:aws:iam::${accountId}:oidc-provider/token\.actions\.githubusercontent\.com$") { Fail 'githubOidcProviderArn is not the GitHub Actions provider for accountId.' }
if ($stateBucket -notmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' -or $artifactBucket -notmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$') { Fail 'bucket names must be valid S3 names.' }
if ($stateBucket -eq $artifactBucket) { Fail 'stateBucketName and artifactBucketName must be separate buckets.' }
if ($null -eq $launchers -or @($launchers).Count -eq 0) { Fail 'at least one launcher is required.' }

$launcherKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($launcher in @($launchers)) {
    $name = [string](Require-Property $launcher 'name')
    $repository = [string](Require-Property $launcher 'repository')
    $environment = [string](Require-Property $launcher 'environment')
    $branch = [string](Require-Property $launcher 'branch')
    $subject = [string](Require-Property $launcher 'githubSubject')
    $sourcePrefix = [string](Require-Property $launcher 'sourcePrefix')
    $projectArn = [string](Require-Property $launcher 'codeBuildProjectArn')
    $additionalProjects = @()
    if ($null -ne $launcher.PSObject.Properties['additionalCodeBuildProjectArns']) { $additionalProjects = @($launcher.additionalCodeBuildProjectArns) }

    if ($name -notmatch '^[a-z0-9-]+$' -or $repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { Fail "launcher '$name' has an invalid name or repository." }
    if ($environment -notin @('staging', 'production')) { Fail "launcher '$name' has an unsupported environment." }
    if (($environment -eq 'staging' -and $branch -ne 'develop') -or ($environment -eq 'production' -and $branch -ne 'main')) { Fail "launcher '$name' has a branch not approved for its environment." }
    if ($subject -ne "repo:$repository`:environment:$environment") { Fail "launcher '$name' does not have the exact GitHub environment subject." }
    if ($subject -match ':pull_request$') { Fail "launcher '$name' cannot trust a pull-request subject." }
    if ($sourcePrefix -notmatch '^[a-z0-9][a-z0-9/_-]*$') { Fail "launcher '$name' has an invalid source prefix." }
    if ($projectArn -notmatch "^arn:aws:codebuild:[a-z0-9-]+:${accountId}:project/[A-Za-z0-9_.-]+$") { Fail "launcher '$name' has a CodeBuild project outside accountId or with an invalid ARN." }
    if ($additionalProjects.Count -gt 0 -and ($name -ne 'k8s-staging' -or $repository -notmatch '^[A-Za-z0-9_.-]+/oficina-k8s-infra$' -or $environment -ne 'staging' -or $branch -ne 'develop' -or $sourcePrefix -ne 'releases/k8s/staging' -or $additionalProjects.Count -ne 1 -or [string]$additionalProjects[0] -ne "arn:aws:codebuild:us-east-1:${accountId}:project/oficina-phase3-foundation-addons")) { Fail "launcher '$name' may add only the exact foundation-addons project from the reviewed Kubernetes staging prefix." }
    if (-not $launcherKeys.Add("$repository/$environment")) { Fail "launcher '$name' duplicates a repository/environment identity." }
}

$validatedStudyRootJustification = $null
if ($operatorIsRoot) {
    if (@($launchers | Where-Object { $_.environment -ne 'staging' }).Count -ne 0) { Fail 'study-root exception is staging-only and cannot include production launchers.' }
    $validatedStudyRootJustification = Get-StudyRootJustification $StudyRootJustification
    Assert-StudyRootEvidence $inputs $validatedStudyRootJustification $InputFile
}

if ([string]::IsNullOrWhiteSpace($CallerArnForTest)) {
    $CallerArnForTest = Get-CurrentCallerArnFromSts
}

$reviewedCallerArn = ConvertTo-ReviewedIdentityArn $CallerArnForTest
if ($reviewedCallerArn -match ':root$' -and -not ($operatorIsRoot -and $AllowStudyRoot -and $reviewedCallerArn -eq $operatorArn)) { Fail 'the current AWS caller is root. Configure and use a dedicated MFA human identity.' }
if ($reviewedCallerArn -notmatch "^arn:aws:iam::${accountId}:(user|role)/.+$" -and -not ($operatorIsRoot -and $reviewedCallerArn -eq $operatorArn)) { Fail 'the current AWS caller does not belong to accountId or is not an IAM user/role.' }
if ($reviewedCallerArn -ne $operatorArn) { Fail 'the current AWS caller does not match reviewed operatorArn.' }

if ($operatorIsRoot) {
    Write-Output 'Deployment inputs are valid under the bounded staging study-root exception; no production launcher is accepted.'
}
else {
    Write-Output 'Deployment inputs are valid; current caller is a non-root identity.'
}
