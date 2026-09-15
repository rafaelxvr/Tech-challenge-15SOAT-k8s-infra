[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InputFile,

    # Used only by offline contract tests. Normal execution always asks STS for the current caller ARN.
    [string]$CallerArnForTest
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
if ($operatorArn -match ':root$') { Fail 'operatorArn cannot be the AWS account root identity; use a dedicated MFA human identity.' }
if ($operatorArn -notmatch "^arn:aws:iam::${accountId}:(user|role)/.+$") { Fail 'operatorArn must be a user or role in accountId.' }
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

    if ($name -notmatch '^[a-z0-9-]+$' -or $repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { Fail "launcher '$name' has an invalid name or repository." }
    if ($environment -notin @('staging', 'production')) { Fail "launcher '$name' has an unsupported environment." }
    if (($environment -eq 'staging' -and $branch -ne 'develop') -or ($environment -eq 'production' -and $branch -ne 'main')) { Fail "launcher '$name' has a branch not approved for its environment." }
    if ($subject -ne "repo:$repository`:environment:$environment") { Fail "launcher '$name' does not have the exact GitHub environment subject." }
    if ($subject -match ':pull_request$') { Fail "launcher '$name' cannot trust a pull-request subject." }
    if ($sourcePrefix -notmatch '^[a-z0-9][a-z0-9/_-]*$') { Fail "launcher '$name' has an invalid source prefix." }
    if ($projectArn -notmatch "^arn:aws:codebuild:[a-z0-9-]+:${accountId}:project/[A-Za-z0-9_.-]+$") { Fail "launcher '$name' has a CodeBuild project outside accountId or with an invalid ARN." }
    if (-not $launcherKeys.Add("$repository/$environment")) { Fail "launcher '$name' duplicates a repository/environment identity." }
}

if ([string]::IsNullOrWhiteSpace($CallerArnForTest)) {
    # Capture only the ARN; never print credentials, account data, or command output.
    $CallerArnForTest = (& aws sts get-caller-identity --query Arn --output text 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($CallerArnForTest)) {
        Fail 'unable to verify the current AWS caller through STS.'
    }
}

if ($CallerArnForTest -match ':root$') { Fail 'the current AWS caller is root. Configure and use a dedicated MFA human identity.' }
if ($CallerArnForTest -notmatch "^arn:aws:iam::${accountId}:(user|role)/.+$") { Fail 'the current AWS caller does not belong to accountId or is not an IAM user/role.' }

Write-Output 'Deployment inputs are valid; current caller is a non-root identity.'
