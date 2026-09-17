[CmdletBinding()]
param(
    [switch]$Run,
    [string]$Context,
    [string]$SourceNamespace = 'oficina-staging',
    [string]$TargetNamespace = 'oficina-production'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Run) {
    Write-Output 'SKIP: pass -Run only against a disposable Cilium-enforced cluster after both platform overlays are applied.'
    exit 0
}

$kubectl = Get-Command kubectl -ErrorAction Stop
$contextArguments = @()
if ($Context) { $contextArguments = @('--context', $Context) }

$cilium = & $kubectl.Source @contextArguments -n kube-system get daemonset cilium -o name 2>$null
if ($LASTEXITCODE -ne 0 -or -not $cilium) {
    throw 'Refusing isolation test: Cilium was not found. Kind default networking does not prove NetworkPolicy enforcement.'
}

$probeName = "network-policy-probe-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
try {
    & $kubectl.Source @contextArguments get namespace $SourceNamespace, $TargetNamespace | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Expected rendered platform namespaces are absent.' }
    foreach ($namespace in @($SourceNamespace, $TargetNamespace)) {
        & $kubectl.Source @contextArguments -n $namespace get networkpolicy default-deny-ingress-egress,oficina-app-allow-required-paths | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Expected rendered platform policies are absent from $namespace." }
    }

    @"
apiVersion: v1
kind: Pod
metadata:
  name: $probeName
  namespace: $SourceNamespace
  labels:
    app.kubernetes.io/name: oficina-app
spec:
  containers:
    - name: probe
      image: registry.k8s.io/e2e-test-images/agnhost:2.45
      args: ["pause"]
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { cpu: 50m, memory: 64Mi }
"@ | & $kubectl.Source @contextArguments apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create the app-labeled platform-policy probe.' }

    & $kubectl.Source @contextArguments -n $SourceNamespace wait --for=condition=Ready "pod/$probeName" --timeout=120s | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Platform-policy probe did not become ready.' }

    $dns = & $kubectl.Source @contextArguments -n $SourceNamespace exec $probeName -- getent hosts kubernetes.default.svc 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $dns) { throw 'App-labeled probe could not resolve CoreDNS through the actual platform policy.' }

    $crossEnvironment = & $kubectl.Source @contextArguments -n $SourceNamespace exec $probeName -- wget -qO- --timeout=5 "http://oficina-app.$TargetNamespace.svc.cluster.local:8080" 2>&1
    if ($LASTEXITCODE -eq 0) { throw "Cross-namespace request unexpectedly succeeded: $crossEnvironment" }

    Write-Output 'PASS: Cilium enforced the rendered platform policy: DNS worked and staging-to-production app traffic was rejected.'
}
finally {
    & $kubectl.Source @contextArguments -n $SourceNamespace delete pod $probeName --ignore-not-found --wait=false 2>$null | Out-Null
}
