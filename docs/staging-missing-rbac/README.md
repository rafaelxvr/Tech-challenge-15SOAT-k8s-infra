# Review-only restoration of missing staging release RBAC

**NOT_APPLIED. No build started. No live two-create plan is claimed.** The exact Kubernetes candidate contains only the namespaced Role and RoleBinding `oficina-release-deployer` in `oficina-staging`. Production is excluded. APP runtime readiness and R4 acceptance remain unproven.

## Evidence and ownership

Source: merged K8S develop `e931decf57a8cfd7d178528bbcfac5432ebaf902` (includes access-entry PR #35). The base [deployer RBAC](../../k8s/platform/base/deployer-rbac.yaml) is owned by `k8s/platform/base/deployer-rbac.yaml`; the five staging additions come from `k8s/platform/overlays/staging/app-bootstrap-rbac.yaml`. The renderer uses the actual staging Kustomize overlay and extracts only the two named objects. It preserves all six base rules and all five staging rules, without adding RBAC inspection/administration permissions.

Diagnostic build `oficina-phase3-foundation-addons:0a0727e4-6208-48bf-be64-433deb4c9324` completed FAILED at 2026-09-19T05:00:47.709Z. Both requests were authorized and returned 404: [redacted audit](eks-audit-redacted.json). `auth can-i --list` exited zero but explicitly warned that the webhook authorizer cannot enumerate all rules. The build's native error string did not match its exact NotFound matcher, so it failed closed after publishing the complete framed diagnostic receipt. This does not invalidate the independent API audit's two 404 results.

The existing private executor is `oficina-phase3-foundation-addons`, role `arn:aws:iam::638612472889:role/oficina-phase3-foundation-addons-role`, with an existing STANDARD EKS entry and cluster-scoped AmazonEKSClusterAdminPolicy. It can inspect/create these objects without IAM or access-policy changes. The normal saved buildspec must never be used for this operation: it runs Terraform against the four Helm releases.

Terraform `infra/foundation-addons` currently owns only Helm charts. `infra/modules/platform-environment` owns AWS routes/access entries, not these raw manifests. Running either full root cannot honestly be described as this two-object change. This candidate uses the existing raw-manifest ownership and a build-specific override; no new Terraform root, state key, provider, import, or mocked live plan is introduced.

## Exact candidate and identity

[staging-release-rbac.json](staging-release-rbac.json) and [staging-release-rbac.yaml](staging-release-rbac.yaml) are source-derived renderings. [candidate-plan.json](candidate-plan.json) is an **offline proposed change inventory**: two creates, zero updates/deletes. JSON SHA256 is `c6376b4c5e4e9e65676612e0843334782806dbfb4b96963d1c14ffd75f2974ac`. [hashes.json](hashes.json) binds the renderer, source templates, outputs and evidence. Source/documentation hashes use UTF-8 text normalized to LF; generated JSON/YAML and copied audit receipts use exact file bytes, preserved by the local .gitattributes file.

| Object | Namespace | Proposed action |
|---|---|---|
| Role/oficina-release-deployer | oficina-staging | Create only if absent |
| RoleBinding/oficina-release-deployer | oficina-staging | Create only if absent |

The sole binding subject is kind `User`, exact name `arn:aws:iam::638612472889:role/oficina-phase3-oficina-app-staging-deploy-role`, API group `rbac.authorization.k8s.io`; the roleRef points only to the namespaced Role. This matches the merged APP access-entry candidate's explicit IAM-ARN username. It does not apply that access entry. No existing K8S executor identity, foundation identity, platform-binding identity, or production binding is replaced or widened.

Reproduce locally (no cloud):

```powershell
pwsh -NoProfile -File scripts/render-staging-deployer-rbac.ps1 -Environment staging -AppDeployerPrincipalArn arn:aws:iam::638612472889:role/oficina-phase3-oficina-app-staging-deploy-role -OutputDirectory docs/staging-missing-rbac
pwsh -NoProfile -File tests/staging-deployer-rbac-candidate-tests.ps1
```

## Guarded foundation execution plan — not executed

1. Prepare a new reviewed StartBuild override for the **existing** foundation project/role/image/VPC, source VersionId `6x_jfXgj82eqK2W9waLmoOpzee33GwUe`. Embed the reviewed helper and the exact two-object JSON in the override; do not execute or replace the downloaded source. Pin payload/buildspec/bundle bytes before approval. Require account `638612472889`, context `arn:aws:eks:us-east-1:638612472889:cluster/oficina-phase3`, staging-only cloud-window evidence with reviewed hash, explicit `ENABLE_STAGING_RBAC_CREATE=true` and separate `APPLY=true`. Without both flags the only permitted path is inspection/server dry-run. No production flags or OIDC/secret changes are introduced.
2. Immediately before dispatch, recheck baseline project configuration, unchanged existing access policy, no active foundation/staging executor builds, exact source version/hash, image digest and cloud-window expiry. The project concurrency limit is one. Do not run concurrently with foundation or platform changes. No new IAM/state-lock permissions are assumed; if coordination cannot be established, stop. The previous foundation baseline/image/source receipts are linked in the evidence index below.
3. In the private executor, run bounded `aws eks update-kubeconfig` for the exact cluster into an owned temp file. Run `kubectl --context <exact-context> get namespace oficina-staging -o json --request-timeout=15s`; require kind Namespace, exact name, `status.phase=Active`, and no deletionTimestamp. **Namespace existence is not proven by the prior namespaced 404 reads.** If absent/inactive, stop; namespace creation is a separately reviewed prerequisite, never an implicit third object.
4. Read both exact objects using `kubectl --context <exact-context> -n oficina-staging get role|rolebinding oficina-release-deployer --ignore-not-found -o json --request-timeout=15s`. Only exit zero plus empty output means absence; nonempty `null`, malformed JSON, wrong kind/name/namespace, 403 or transport errors fail. If both exist and canonical rules/subjects/roleRef/owned labels match the candidate, return **NO_OP / zero changes**. If either differs, stop; if only one exists, stop for partial-state review. For both absent, run `kubectl --context <exact-context> -n oficina-staging create --dry-run=server -f <hash-verified-two-object-json> -o json --request-timeout=15s`, save the server result hash and exact proposed two creates. Admission errors or any additional object fail. This live check is pending and is required before creation approval.
5. Only after approval of those exact inputs/server checks and explicit gates, use create-only requests in Role-then-RoleBinding order. Do not use apply/replace/patch/update or `--force`; an object appearing after preflight yields AlreadyExists and stops, preserving it. Save each create response's UID/resourceVersion/creationTimestamp and body hash, then read back both exact objects and verify canonical content. Capture terminal build, framed receipt, audit records, no production requests and unchanged project configuration. On any failure, stop without automatic retry or cleanup; report partial creation. APP launch and access-entry apply are separate actions and remain prohibited here.

The exact future create commands (one-object files split from the hash-bound List) are:

```text
kubectl --context arn:aws:eks:us-east-1:638612472889:cluster/oficina-phase3 --namespace oficina-staging create -f role.json -o json --request-timeout=15s
kubectl --context arn:aws:eks:us-east-1:638612472889:cluster/oficina-phase3 --namespace oficina-staging create -f rolebinding.json -o json --request-timeout=15s
```

No executable apply/StartBuild payload is issued by this review-only render. The live Namespace/admission prerequisites prevent claiming a ready-to-apply plan today; the next private plan-only override must be independently reviewed.

## Rollback limited to this change

Rollback is not automatic. Only objects confirmed created by the approved build may be removed, in reverse order. First compare live UID and canonical content to that build's create receipts; reject missing/different/replaced objects or subsequent edits. Use Kubernetes DELETE requests with `DeleteOptions.preconditions.uid` and `preconditions.resourceVersion` from that fresh checked read, scoped to these exact endpoints:

```text
DELETE /apis/rbac.authorization.k8s.io/v1/namespaces/oficina-staging/rolebindings/oficina-release-deployer
DELETE /apis/rbac.authorization.k8s.io/v1/namespaces/oficina-staging/roles/oficina-release-deployer
```

The rollback request body is `{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"<created-object-UID>","resourceVersion":"<fresh-verified-resourceVersion>"}}`; placeholders must be replaced from real receipts, never guessed. UID/resourceVersion preconditions prevent deleting a replacement or concurrent edit. No namespace, access entry, service account, deployment, chart, AWS resource, other Role/RoleBinding or production object is included. If one create failed, rollback may address only the object whose creation was actually proven.

## Checks and evidence locations

Focused offline contract: 13 assertions; deterministic render, exact two identities, 11 source-derived rules, no RBAC administration, digest binding, and rejection of production/wrong-account input. The first test run found dictionary serialization in the proposed inventory; conversion to explicit PSCustomObject entries fixed it. This was a local serialization failure, not a cloud attempt.

Operator-held receipts: `D:/repository/private-executor-rbac-inventory-20260919/continuation-candidate/execution/diagnostic-framed-receipt.json` SHA256 `25e7bad18f9041816a3c73fd1ae327a8b8a93cf7f6b746347bc2623fed86413d`; `diagnostic-summary.json` SHA256 `2d0e275f687bf6d1be2df5449bd3a773c7f42ccfc963d55a960789c10982a5cd`; `receipt-hashes.json` SHA256 `98ecdf18000466658323d3756f3f5aca802309b7d9ea834c6f5de5d3259d14fe`. The redacted audit is copied alongside this document with hash `3b85c79c24c959a15637c73c38d3443478223ddf578ca30e557faed00f1a11c3`.

Remaining prerequisites: live Namespace/admission verification, separately reviewed plan-only and gated create override, then separate APP identity mapping. This candidate establishes no runtime success and does not change R4/submission status.
