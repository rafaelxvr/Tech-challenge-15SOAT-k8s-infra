# Staging APP bootstrap contract

This change provides repository source and offline artifacts for the APP first-deployment adapter. It neither installs RBAC nor deploys a workload. Production overlays, the shared Role, Terraform deployment inputs and cloud apply guards are unchanged.

## Staging permissions

The staging overlay appends exactly these rules to the existing namespaced `oficina-release-deployer` Role:

| Resource | Verbs | Name restriction |
| --- | --- | --- |
| core `serviceaccounts` | `get` | `oficina-app` |
| core `serviceaccounts` | `create` | Namespace-scoped; Kubernetes cannot restrict create using `resourceNames` |
| batch `jobs` | `get`, `list`, `watch`, `create` | Namespace-scoped; migration Job names include the reviewed release digest |
| autoscaling `horizontalpodautoscalers` | `delete` | `oficina-app` |

The Job reads support `kubectl wait` and completion readback; the HPA delete supports draining existing FirstWriter workloads. There are no new Secret reads, role/rolebinding mutations, Job deletion, service-account updates or wildcard grants. The existing RoleBinding still selects the reviewed `DeployerPrincipalArn`; the operator must bind the actual APP executor identity rather than assume the platform executor identity is interchangeable.

Namespace-wide SA/Job creation is a material RBAC boundary: a trusted executor holding these permissions can create objects beyond this adapter's fixed names. The adapter only creates the reviewed APP service account and migration Job. If policy requires server-side restrictions on names, images or service-account selection, review corresponding admission policy before activation; this patch does not claim RBAC enforces those fields.

## Deterministic bundle and digest binding

First run the existing `scripts/render-platform.ps1` with reviewed staging inputs. Review the resulting `platform-staging.yaml`, then pass its exact SHA256 to the bundle renderer:

```powershell
./scripts/render-staging-app-workload.ps1 -Environment staging `
  -PlatformManifestFile ./artifacts/platform-staging.yaml `
  -ExpectedPlatformSha256 <reviewed-platform-manifest-sha256> `
  -OutputDirectory ./artifacts/app-bootstrap
```

The renderer uses local Terraform `console`/`yamldecode` in an isolated empty temporary directory. Terraform is already pinned to 1.15.8 by CI. This operation initializes no backend/provider, contacts no cluster, and makes no AWS call. Input placeholders of the form `${...}`, mismatched hashes, production resources, unpinned images and mismatched staging IRSA references are rejected.

`app-workload-staging.json` is a Kubernetes `v1/List` containing exactly Deployment, ServiceAccount and HPA in that order. The Deployment retains the platform pod configuration (probes, resources, CSI, references and security settings), with `replicas: 0` and `Recreate`. The service account retains IRSA; the HPA retains minimum 1/maximum 2. JSON keys use ordinal order, encoding is UTF-8 without BOM, and no timestamp or temporary path enters either output.

`app-workload-staging.receipt.json` records `platformManifestSha256`, `stagingWorkloadSha256`, staging environment, APP image, IRSA reference and `RENDERED_ONLY`. Copy `stagingWorkloadSha256` into the separately reviewed APP release and provide the bundle as its `-StagingWorkloadFile`. The receipt binds bytes, not deployment authorization or source provenance; include the reviewed K8S source commit and input evidence in the release review.

**Do not apply the entire List directly.** The APP adapter creates SA/Deployment with zero writers, runs migration, waits for rollout, and only then restores the HPA. `APP_DEPLOYMENT_DISABLED` in the APP executor remains an external activation boundary.

## Remaining external inputs and verification

The future staging run still requires reviewed runtime IRSA and APP executor principals; APP/migration/deployer digests and provenance; release/platform/archive hashes; lock bucket and approved cloud window; a separate approved platform apply for the staging Role; and the APP executor integration. Existing namespace, Service/routing, CSI/policies, public ConfigMap, runtime references, migration Secret and migration service account must be provisioned through their own platform/DB contracts. This bundle does not provision credentials or grant platform access.

`tests/staging-app-workload-tests.ps1` checks exact staging verbs/names, unchanged production permissions/capacity, production rejection, preservation of platform configuration, zero writers, digest binding, deterministic repeated rendering and unresolved-token rejection. CI runs it alongside the existing platform tests. These are local contract checks, not live runtime evidence.
