[CmdletBinding()]
param(
    [switch]$Run,
    [string]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Run) {
    Write-Output 'SKIP: pass -Run only against a disposable cluster with Cilium enforcing NetworkPolicy.'
    exit 0
}

$kubectl = Get-Command kubectl -ErrorAction Stop
$contextArguments = @()
if ($Context) { $contextArguments = @('--context', $Context) }

$cilium = & $kubectl.Source @contextArguments -n kube-system get daemonset cilium -o name 2>$null
if ($LASTEXITCODE -ne 0 -or -not $cilium) {
    throw 'Refusing isolation test: Cilium was not found. Kind default networking does not prove NetworkPolicy enforcement.'
}

$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$sourceNamespace = "oficina-isolation-source-$suffix"
$targetNamespace = "oficina-isolation-target-$suffix"
$targetPod = 'target'

try {
    @"
apiVersion: v1
kind: Namespace
metadata:
  name: $sourceNamespace
---
apiVersion: v1
kind: Namespace
metadata:
  name: $targetNamespace
---
apiVersion: v1
kind: Pod
metadata:
  name: $targetPod
  namespace: $targetNamespace
  labels: { app: target }
spec:
  containers:
    - name: http
      image: registry.k8s.io/e2e-test-images/agnhost:2.45
      args: ["netexec", "--http-port=8080"]
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { cpu: 50m, memory: 64Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: target
  namespace: $targetNamespace
spec:
  selector: { app: target }
  ports: [{ port: 8080, targetPort: 8080 }]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: $targetNamespace
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
"@ | & $kubectl.Source @contextArguments apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create isolation fixture.' }

    & $kubectl.Source @contextArguments -n $targetNamespace wait --for=condition=Ready "pod/$targetPod" --timeout=120s | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Isolation fixture target did not become ready.' }

    $probe = & $kubectl.Source @contextArguments -n $sourceNamespace run probe --rm -i --restart=Never --image=registry.k8s.io/e2e-test-images/agnhost:2.45 -- wget -qO- --timeout=5 "http://target.$targetNamespace.svc.cluster.local:8080" 2>&1
    if ($LASTEXITCODE -eq 0) { throw "Cross-namespace request unexpectedly succeeded: $probe" }

    Write-Output 'PASS: Cilium enforced default-deny ingress and rejected the cross-namespace request.'
}
finally {
    & $kubectl.Source @contextArguments delete namespace $sourceNamespace, $targetNamespace --ignore-not-found --wait=false 2>$null | Out-Null
}
