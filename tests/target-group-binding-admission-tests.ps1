[CmdletBinding()]
param(
    [switch]$Run,
    [string]$KubeContext,
    [string]$StagingTargetGroupArn,
    [string]$ProductionTargetGroupArn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$renderer = Join-Path $repoRoot 'scripts/render-target-group-binding-admission.ps1'
$template = Get-Content -LiteralPath (Join-Path $repoRoot 'k8s/platform/admission/target-group-binding-admission.yaml') -Raw
$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("oficina-target-binding-admission-test-" + [guid]::NewGuid())
$sampleStagingArn = 'arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/oficina-phase3-staging-app/1234567890abcdef'
$sampleProductionArn = 'arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/oficina-phase3-production-app/abcdef1234567890'

function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) {
    if (-not $Text.Contains($Expected)) { throw $Message }
}

function Invoke-Kubectl([string[]]$Arguments) {
    if ($KubeContext) { & kubectl --context $KubeContext @Arguments | Out-Null } else { & kubectl @Arguments | Out-Null }
    return $LASTEXITCODE
}

try {
    Assert-Contains $template 'kind: ValidatingAdmissionPolicy' 'TargetGroupBinding admission contract must use the native ValidatingAdmissionPolicy API.'
    Assert-Contains $template 'failurePolicy: Fail' 'Admission failures must fail closed.'
    Assert-Contains $template 'operations: ["CREATE", "UPDATE"]' 'Admission contract must cover direct create and patch/update requests.'
    Assert-Contains $template "object.metadata.namespace == 'oficina-staging'" 'Admission contract must bind staging to its exact namespace.'
    Assert-Contains $template "object.metadata.namespace == 'oficina-production'" 'Admission contract must bind production to its exact namespace.'
    Assert-Contains $template "object.metadata.name == 'oficina-app'" 'Admission contract must constrain the stable binding name.'
    Assert-Contains $template "request.dryRun == true" 'Only a non-persisted server-side dry-run create probe may use a unique binding name.'
    Assert-Contains $template "object.metadata.labels['oficina.io/managed-by'] == 'platform-binding'" 'Admission contract must require trusted platform-binding ownership.'

    $renderedPolicyPath = & $renderer -StagingTargetGroupArn $sampleStagingArn -ProductionTargetGroupArn $sampleProductionArn -OutputDirectory $tempDirectory
    $renderedPolicy = Get-Content -LiteralPath $renderedPolicyPath -Raw
    Assert-Contains $renderedPolicy $sampleStagingArn 'Rendered admission policy must contain the exact staging target group ARN.'
    Assert-Contains $renderedPolicy $sampleProductionArn 'Rendered admission policy must contain the exact production target group ARN.'
    if ($renderedPolicy -match '\$\{[A-Z_]+\}') { throw 'Rendered admission policy still contains an unresolved token.' }

    $swappedArnRejected = $false
    try {
        & $renderer -StagingTargetGroupArn $sampleProductionArn -ProductionTargetGroupArn $sampleStagingArn -OutputDirectory $tempDirectory | Out-Null
    }
    catch { $swappedArnRejected = $true }
    if (-not $swappedArnRejected) { throw 'Admission renderer accepted cross-environment target group ARNs.' }

    $wrongReviewedNameRejected = $false
    try {
        & $renderer -StagingTargetGroupArn 'arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/oficina-staging-app/1234567890abcdef' -ProductionTargetGroupArn $sampleProductionArn -OutputDirectory $tempDirectory | Out-Null
    }
    catch { $wrongReviewedNameRejected = $true }
    if (-not $wrongReviewedNameRejected) { throw 'Admission renderer accepted an ARN outside the reviewed oficina-phase3 Terraform target-group name.' }

    foreach ($injectedArn in @(
        "$sampleStagingArn' || true || '",
        "$sampleStagingArn; object.spec.targetGroupARN == 'anything'",
        "$sampleStagingArn`napiVersion: v1"
    )) {
        $injectionRejected = $false
        try { & $renderer -StagingTargetGroupArn $injectedArn -ProductionTargetGroupArn $sampleProductionArn -OutputDirectory $tempDirectory | Out-Null }
        catch { $injectionRejected = $true }
        if (-not $injectionRejected) { throw 'Admission renderer accepted an ARN containing CEL or YAML injection syntax.' }
    }

    if (-not $Run) {
        Write-Output 'SKIP: pass -Run with an authenticated platform-binding context, exact target group ARNs and an already installed policy to run server-side create and patch admission checks.'
        return
    }

    if (-not $StagingTargetGroupArn -or -not $ProductionTargetGroupArn) { throw 'Live admission test requires both exact target group ARN arguments.' }
    $serverVersion = if ($KubeContext) { & kubectl --context $KubeContext version --output=json } else { & kubectl version --output=json }
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read Kubernetes server version.' }
    $serverMinor = [int](($serverVersion | ConvertFrom-Json).serverVersion.minor -replace '\D', '')
    if ($serverMinor -lt 30) { throw 'ValidatingAdmissionPolicy requires Kubernetes 1.30 or newer.' }

    if ((Invoke-Kubectl @('get', 'customresourcedefinition', 'targetgroupbindings.elbv2.k8s.aws')) -ne 0) { throw 'AWS Load Balancer Controller TargetGroupBinding CRD is not installed.' }
    $policyJson = if ($KubeContext) { & kubectl --context $KubeContext get validatingadmissionpolicy oficina-target-group-binding-contract --output=json } else { & kubectl get validatingadmissionpolicy oficina-target-group-binding-contract --output=json }
    if ($LASTEXITCODE -ne 0) { throw 'The rendered TargetGroupBinding admission policy is not installed.' }
    $policyText = $policyJson | Out-String
    Assert-Contains $policyText $StagingTargetGroupArn 'Installed policy does not contain the supplied exact staging target group ARN.'
    Assert-Contains $policyText $ProductionTargetGroupArn 'Installed policy does not contain the supplied exact production target group ARN.'

    $canCreate = if ($KubeContext) { & kubectl --context $KubeContext auth can-i create targetgroupbindings.elbv2.k8s.aws --namespace oficina-staging } else { & kubectl auth can-i create targetgroupbindings.elbv2.k8s.aws --namespace oficina-staging }
    if ($LASTEXITCODE -ne 0 -or $canCreate.Trim() -ne 'yes') { throw 'Live test must run as the platform-binding principal with the intentionally unrestricted create permission.' }
    $canPatch = if ($KubeContext) { & kubectl --context $KubeContext auth can-i patch targetgroupbindings.elbv2.k8s.aws/oficina-app --namespace oficina-staging } else { & kubectl auth can-i patch targetgroupbindings.elbv2.k8s.aws/oficina-app --namespace oficina-staging }
    if ($LASTEXITCODE -ne 0 -or $canPatch.Trim() -ne 'yes') { throw 'Live test must run as the platform-binding principal with name-limited patch RBAC.' }

    $existingBindingJson = if ($KubeContext) { & kubectl --context $KubeContext get targetgroupbindings.elbv2.k8s.aws/oficina-app --namespace oficina-staging --output=json } else { & kubectl get targetgroupbindings.elbv2.k8s.aws/oficina-app --namespace oficina-staging --output=json }
    if ($LASTEXITCODE -ne 0) { throw 'Live update test requires the existing reviewed oficina-staging/oficina-app TargetGroupBinding.' }
    $existingBinding = $existingBindingJson | ConvertFrom-Json
    if ($existingBinding.spec.targetGroupARN -ne $StagingTargetGroupArn) { throw 'Existing reviewed staging binding does not use the supplied exact staging target group ARN.' }
    if ($existingBinding.metadata.labels.'app.kubernetes.io/managed-by' -ne 'oficina-k8s-infra' -or $existingBinding.metadata.labels.'oficina.io/managed-by' -ne 'platform-binding') { throw 'Existing reviewed staging binding is missing the trusted managed-by labels.' }

    $createProbeName = 'oficina-app-admission-probe-' + [guid]::NewGuid().ToString('N')
    $createManifestPath = Join-Path $tempDirectory 'staging-binding-create.yaml'
    @"
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: $createProbeName
  namespace: oficina-staging
  labels:
    app.kubernetes.io/managed-by: oficina-k8s-infra
    oficina.io/managed-by: platform-binding
spec:
  serviceRef:
    name: oficina-app
    port: 8080
  targetGroupARN: $StagingTargetGroupArn
  targetType: ip
"@ | Set-Content -LiteralPath $createManifestPath -NoNewline
    if ((Invoke-Kubectl @('create', '--filename', $createManifestPath, '--dry-run=server')) -ne 0) { throw 'Admission policy rejected the reviewed direct staging binding create.' }
    Write-Output 'PASS: server-side dry-run CREATE accepted the unique reviewed staging probe.'

    $negativeCreateManifestPath = Join-Path $tempDirectory 'staging-binding-create-retarget.yaml'
    (Get-Content -LiteralPath $createManifestPath -Raw).Replace($StagingTargetGroupArn, $ProductionTargetGroupArn) | Set-Content -LiteralPath $negativeCreateManifestPath -NoNewline
    $negativeCreateOutput = if ($KubeContext) { & kubectl --context $KubeContext create --filename $negativeCreateManifestPath --dry-run=server 2>&1 } else { & kubectl create --filename $negativeCreateManifestPath --dry-run=server 2>&1 }
    if ($LASTEXITCODE -eq 0) { throw 'Admission policy allowed a direct staging create to the production target group.' }
    Assert-Contains ($negativeCreateOutput | Out-String) "must use its environment's exact reviewed target group ARN" 'Direct staging-to-production create was denied for an unexpected reason.'
    Write-Output 'PASS: server-side dry-run CREATE denied the staging-to-production retarget.'

    $positivePatch = @{ metadata = @{ labels = @{ 'app.kubernetes.io/managed-by' = 'oficina-k8s-infra'; 'oficina.io/managed-by' = 'platform-binding' } }; spec = @{ targetGroupARN = $StagingTargetGroupArn } } | ConvertTo-Json -Compress
    if ((Invoke-Kubectl @('patch', 'targetgroupbindings.elbv2.k8s.aws/oficina-app', '--namespace', 'oficina-staging', '--type', 'merge', '--patch', $positivePatch, '--dry-run=server')) -ne 0) { throw 'Admission policy rejected the reviewed staging binding patch.' }
    Write-Output 'PASS: server-side dry-run UPDATE accepted the existing reviewed staging binding.'

    $negativePatch = @{ metadata = @{ labels = @{ 'app.kubernetes.io/managed-by' = 'oficina-k8s-infra'; 'oficina.io/managed-by' = 'platform-binding' } }; spec = @{ targetGroupARN = $ProductionTargetGroupArn } } | ConvertTo-Json -Compress
    $negativeOutput = if ($KubeContext) { & kubectl --context $KubeContext patch targetgroupbindings.elbv2.k8s.aws/oficina-app --namespace oficina-staging --type merge --patch $negativePatch --dry-run=server 2>&1 } else { & kubectl patch targetgroupbindings.elbv2.k8s.aws/oficina-app --namespace oficina-staging --type merge --patch $negativePatch --dry-run=server 2>&1 }
    if ($LASTEXITCODE -eq 0) { throw 'Admission policy allowed a direct staging binding patch to the production target group.' }
    Assert-Contains ($negativeOutput | Out-String) "must use its environment's exact reviewed target group ARN" 'Direct staging-to-production patch was denied for an unexpected reason.'
    Write-Output 'PASS: server-side dry-run UPDATE denied the staging-to-production retarget.'
}
finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
