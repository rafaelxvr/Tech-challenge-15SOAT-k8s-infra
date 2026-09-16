[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$checker = Join-Path $repoRoot 'scripts/check-deployment-inputs.ps1'
$tfvarsWriter = Join-Path $repoRoot 'scripts/new-bootstrap-tfvars.ps1'
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

function Get-StudyJustification([string]$Purpose = 'Validate the bounded staging bootstrap rehearsal.') {
    return (@{
        studyScope = 'phase-3-staging-bootstrap-study'
        operatorApprovedPurpose = $Purpose
        boundedWindowReference = 'window-bootstrap-20260916'
    } | ConvertTo-Json -Compress)
}

function Get-JustificationFingerprint([string]$Justification) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Justification)
    return ([System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function Write-StudyEvidence([string]$Name, [string]$Justification, [string]$Scope = 'phase-3-staging-bootstrap-study', [string]$Window = 'window-bootstrap-20260916') {
    $path = Join-Path $tempDirectory $Name
    @{
        status = 'APPROVED_FOR_STUDY_STAGING'
        environment = 'staging'
        timestampUtc = '2026-09-16T12:00:00Z'
        justificationFingerprint = Get-JustificationFingerprint $Justification
        studyScope = $Scope
        boundedWindowReference = $Window
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -NoNewline
}

function Assert-StudyRootRejected([string]$Name, [hashtable]$Fixture, [string]$Justification, [switch]$WithSwitch) {
    $path = Write-Fixture $Name $Fixture
    $rejected = $false
    try {
        $arguments = @{ InputFile = $path; CallerArnForTest = 'arn:aws:iam::123456789012:root' }
        if ($WithSwitch) {
            $arguments.AllowStudyRoot = $true
            $arguments.StudyRootJustification = $Justification
        }
        & $checker @arguments | Out-Null
    }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Expected study-root fixture '$Name' to be rejected." }
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

    # Real runs resolve the CLI safely: an explicit unavailable override fails before a shell
    # invocation, while an injected local executable can supply the same non-secret STS ARN.
    $originalAwsCliOverride = $env:OFICINA_AWS_CLI_PATH
    try {
        $env:OFICINA_AWS_CLI_PATH = Join-Path $tempDirectory 'missing-aws.exe'
        $unavailableRejected = $false
        try { & $checker -InputFile $validPath | Out-Null } catch { $unavailableRejected = $_.Exception.Message -match 'OFICINA_AWS_CLI_PATH' }
        if (-not $unavailableRejected) { throw 'Expected an unavailable AWS CLI override to fail with the controlled resolution error.' }

        $awsStub = Join-Path $tempDirectory 'aws-stub.cmd'
        @('@echo off', 'echo arn:aws:iam::123456789012:role/phase3-human', 'exit /b 0') | Set-Content -LiteralPath $awsStub -NoNewline:$false
        $env:OFICINA_AWS_CLI_PATH = $awsStub
        & $checker -InputFile $validPath | Out-Null
    }
    finally {
        if ($null -eq $originalAwsCliOverride) { Remove-Item Env:OFICINA_AWS_CLI_PATH -ErrorAction SilentlyContinue }
        else { $env:OFICINA_AWS_CLI_PATH = $originalAwsCliOverride }
    }

    # A matching assumed-role caller is normalized to its reviewed IAM role ARN.
    & $checker -InputFile $validPath -CallerArnForTest 'arn:aws:sts::123456789012:assumed-role/phase3-human/session-123' | Out-Null

    $tfvarsPath = Join-Path $tempDirectory 'bootstrap.tfvars.json'
    & $tfvarsWriter -InputFile $validPath -OutputFile $tfvarsPath -CallerArnForTest 'arn:aws:iam::123456789012:role/phase3-human' | Out-Null
    $tfvars = Get-Content -LiteralPath $tfvarsPath -Raw | ConvertFrom-Json
    if ($tfvars.account_id -ne '123456789012' -or $tfvars.launchers.'k8s-staging'.source_prefix -ne 'releases/k8s/staging') { throw 'Expected writer to produce usable Terraform variable input.' }

    $addonsLauncher = $valid.Clone(); $addonsLauncher.launchers = @($valid.launchers[0].Clone()); $addonsLauncher.launchers[0].repository = 'rafaelxvr/Tech-challenge-15SOAT-k8s-infra'; $addonsLauncher.launchers[0].githubSubject = 'repo:rafaelxvr/Tech-challenge-15SOAT-k8s-infra:environment:staging'; $addonsLauncher.launchers[0].additionalCodeBuildProjectArns = @('arn:aws:codebuild:us-east-1:123456789012:project/oficina-phase3-foundation-addons')
    & $checker -InputFile (Write-Fixture 'foundation-addons-launcher' $addonsLauncher) -CallerArnForTest 'arn:aws:iam::123456789012:role/phase3-human' | Out-Null
    $wrongAddonsTarget = $addonsLauncher.Clone(); $wrongAddonsTarget.launchers = @($addonsLauncher.launchers[0].Clone()); $wrongAddonsTarget.launchers[0].additionalCodeBuildProjectArns = @('arn:aws:codebuild:us-east-1:123456789012:project/unreviewed-project')
    Assert-Rejected 'unreviewed-foundation-addons-target' $wrongAddonsTarget
    $wrongAddonsLauncher = $addonsLauncher.Clone(); $wrongAddonsLauncher.launchers = @($addonsLauncher.launchers[0].Clone()); $wrongAddonsLauncher.launchers[0].name = 'other-staging'
    Assert-Rejected 'unreviewed-foundation-addons-launcher' $wrongAddonsLauncher

    $wrongSubject = $valid.Clone(); $wrongSubject.launchers = @($valid.launchers[0].Clone()); $wrongSubject.launchers[0].githubSubject = 'repo:example/oficina-k8s-infra:pull_request'
    Assert-Rejected 'wrong-subject' $wrongSubject

    $missingInput = $valid.Clone(); $missingInput.Remove('artifactBucketName')
    Assert-Rejected 'missing-input' $missingInput

    $rootIdentity = $valid.Clone(); $rootIdentity.operatorArn = 'arn:aws:iam::123456789012:root'
    Assert-Rejected 'root-operator' $rootIdentity

    # Root access remains denied by default. The only exception is a bounded staging rehearsal,
    # backed by a redacted local approval record whose fingerprint matches the structured reason.
    $studyJustification = Get-StudyJustification
    Write-StudyEvidence 'study-root-evidence.json' $studyJustification
    $rootStudy = $valid.Clone(); $rootStudy.operatorArn = 'arn:aws:iam::123456789012:root'; $rootStudy.studyRootException = @{ evidenceRecord = 'study-root-evidence.json' }
    Assert-StudyRootRejected 'study-root-no-switch' $rootStudy $studyJustification
    $rootStudyPath = Write-Fixture 'study-root-valid' $rootStudy
    & $checker -InputFile $rootStudyPath -CallerArnForTest 'arn:aws:iam::123456789012:root' -AllowStudyRoot -StudyRootJustification $studyJustification | Out-Null
    $rootTfvars = Join-Path $tempDirectory 'study-root-bootstrap.tfvars.json'
    & $tfvarsWriter -InputFile $rootStudyPath -OutputFile $rootTfvars -CallerArnForTest 'arn:aws:iam::123456789012:root' -AllowStudyRoot -StudyRootJustification $studyJustification | Out-Null

    $productionRoot = $rootStudy.Clone(); $productionRoot.launchers = @($rootStudy.launchers[0].Clone()); $productionRoot.launchers[0].name = 'k8s-production'; $productionRoot.launchers[0].environment = 'production'; $productionRoot.launchers[0].branch = 'main'; $productionRoot.launchers[0].githubSubject = 'repo:example/oficina-k8s-infra:environment:production'; $productionRoot.launchers[0].sourcePrefix = 'releases/k8s/production'; $productionRoot.launchers[0].codeBuildProjectArn = 'arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-production'
    Assert-StudyRootRejected 'study-root-production' $productionRoot $studyJustification -WithSwitch

    $vagueJustification = Get-StudyJustification 'Approved task.'
    Write-StudyEvidence 'study-root-vague-evidence.json' $vagueJustification
    $vagueRoot = $rootStudy.Clone(); $vagueRoot.studyRootException = @{ evidenceRecord = 'study-root-vague-evidence.json' }
    Assert-StudyRootRejected 'study-root-vague' $vagueRoot $vagueJustification -WithSwitch

    $sensitiveJustification = Get-StudyJustification 'Validate bounded staging rehearsal with AKIA1234567890ABCDEF credentials.'
    Write-StudyEvidence 'study-root-sensitive-evidence.json' $sensitiveJustification
    $sensitiveRoot = $rootStudy.Clone(); $sensitiveRoot.studyRootException = @{ evidenceRecord = 'study-root-sensitive-evidence.json' }
    Assert-StudyRootRejected 'study-root-sensitive' $sensitiveRoot $sensitiveJustification -WithSwitch

    $accountIdJustification = Get-StudyJustification 'Validate bounded staging rehearsal for 123456789012.'
    Write-StudyEvidence 'study-root-account-id-evidence.json' $accountIdJustification
    $accountIdRoot = $rootStudy.Clone(); $accountIdRoot.studyRootException = @{ evidenceRecord = 'study-root-account-id-evidence.json' }
    Assert-StudyRootRejected 'study-root-account-id' $accountIdRoot $accountIdJustification -WithSwitch

    Write-StudyEvidence 'study-root-sensitive-record.json' $studyJustification
    $sensitiveEvidencePath = Join-Path $tempDirectory 'study-root-sensitive-record.json'
    $sensitiveEvidence = Get-Content -LiteralPath $sensitiveEvidencePath -Raw | ConvertFrom-Json
    $sensitiveEvidence | Add-Member -NotePropertyName redactionCheck -NotePropertyValue 'AKIA1234567890ABCDEF'
    $sensitiveEvidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sensitiveEvidencePath -NoNewline
    $sensitiveRecordRoot = $rootStudy.Clone(); $sensitiveRecordRoot.studyRootException = @{ evidenceRecord = 'study-root-sensitive-record.json' }
    Assert-StudyRootRejected 'study-root-sensitive-record' $sensitiveRecordRoot $studyJustification -WithSwitch

    Write-StudyEvidence 'study-root-account-id-record.json' $studyJustification
    $accountIdEvidencePath = Join-Path $tempDirectory 'study-root-account-id-record.json'
    $accountIdEvidence = Get-Content -LiteralPath $accountIdEvidencePath -Raw | ConvertFrom-Json
    $accountIdEvidence | Add-Member -NotePropertyName redactionCheck -NotePropertyValue '123456789012'
    $accountIdEvidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $accountIdEvidencePath -NoNewline
    $accountIdRecordRoot = $rootStudy.Clone(); $accountIdRecordRoot.studyRootException = @{ evidenceRecord = 'study-root-account-id-record.json' }
    Assert-StudyRootRejected 'study-root-account-id-record' $accountIdRecordRoot $studyJustification -WithSwitch

    $missingEvidenceRoot = $rootStudy.Clone(); $missingEvidenceRoot.studyRootException = @{ evidenceRecord = 'missing-study-record.json' }
    Assert-StudyRootRejected 'study-root-missing-evidence' $missingEvidenceRoot $studyJustification -WithSwitch

    Write-StudyEvidence 'study-root-mismatch-evidence.json' (Get-StudyJustification 'Validate a different bounded staging rehearsal.')
    $mismatchedRoot = $rootStudy.Clone(); $mismatchedRoot.studyRootException = @{ evidenceRecord = 'study-root-mismatch-evidence.json' }
    Assert-StudyRootRejected 'study-root-mismatched-evidence' $mismatchedRoot $studyJustification -WithSwitch

    $rootCaller = $validPath
    $callerRejected = $false
    try { & $checker -InputFile $rootCaller -CallerArnForTest 'arn:aws:iam::123456789012:root' | Out-Null } catch { $callerRejected = $true }
    if (-not $callerRejected) { throw 'Expected root STS caller to be rejected.' }

    $differentCallerRejected = $false
    try { & $checker -InputFile $validPath -CallerArnForTest 'arn:aws:iam::123456789012:role/another-human' | Out-Null } catch { $differentCallerRejected = $true }
    if (-not $differentCallerRejected) { throw 'Expected same-account but unreviewed STS caller to be rejected.' }

    Write-Output 'PASS: deployment input contract accepts reviewed non-root callers and only a fingerprinted, staging-only study-root exception.'
}
finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
