[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$checker = Join-Path $repoRoot 'scripts/check-deployment-inputs.ps1'
$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("oficina-input-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempDirectory | Out-Null

function Write-Fixture([string]$Name, [hashtable]$Fixture) {
    $path = Join-Path $tempDirectory "$Name.json"
    $Fixture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -NoNewline
    return $path
}

function Assert-Rejected([string]$Name, [hashtable]$Fixture) {
    $path = Write-Fixture $Name $Fixture
    $rejected = $false
    try {
        & $checker -InputFile $path -CallerArnForTest 'arn:aws:iam::123456789012:role/phase3-human' | Out-Null
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) { throw "Expected fixture '$Name' to be rejected." }
}

try {
    $valid = @{
        accountId = '123456789012'; region = 'us-east-1'; operatorArn = 'arn:aws:iam::123456789012:role/phase3-human'
        githubOidcProviderArn = 'arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com'
        stateBucketName = 'oficina-state-example'; artifactBucketName = 'oficina-artifacts-example'
        launchers = @(@{ name = 'k8s-staging'; repository = 'example/oficina-k8s-infra'; environment = 'staging'; branch = 'develop'; githubSubject = 'repo:example/oficina-k8s-infra:environment:staging'; sourcePrefix = 'releases/k8s/staging'; codeBuildProjectArn = 'arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-staging' })
    }
    $validPath = Write-Fixture 'valid' $valid
    & $checker -InputFile $validPath -CallerArnForTest 'arn:aws:iam::123456789012:role/phase3-human' | Out-Null

    $wrongSubject = $valid.Clone(); $wrongSubject.launchers = @($valid.launchers[0].Clone()); $wrongSubject.launchers[0].githubSubject = 'repo:example/oficina-k8s-infra:pull_request'
    Assert-Rejected 'wrong-subject' $wrongSubject

    $missingInput = $valid.Clone(); $missingInput.Remove('artifactBucketName')
    Assert-Rejected 'missing-input' $missingInput

    $rootIdentity = $valid.Clone(); $rootIdentity.operatorArn = 'arn:aws:iam::123456789012:root'
    Assert-Rejected 'root-operator' $rootIdentity

    $rootCaller = $validPath
    $callerRejected = $false
    try { & $checker -InputFile $rootCaller -CallerArnForTest 'arn:aws:iam::123456789012:root' | Out-Null } catch { $callerRejected = $true }
    if (-not $callerRejected) { throw 'Expected root STS caller to be rejected.' }

    Write-Output 'PASS: deployment input contract accepts valid input and rejects missing, root, and pull-request identity cases.'
}
finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
