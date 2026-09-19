# Review-only Namespace prerequisite and release RBAC

**NOT_STARTED / NOT_APPLIED.** The authorized private diagnostic `oficina-phase3-foundation-addons:feee01a4-7d61-47b5-a293-8030c940499e` returned a verified authorized HTTP 404 for Namespace `oficina-staging`. Its summary SHA256 is `44ab4309e04045772c0a7d260573e58e8198c23927561f8004b56df18aa104b0`; redacted audit SHA256 `8510ef447685d3b5a6d727024aab20f72fe564212bf48bee69c4db4e8fa9a537`. Operator-held receipts: `D:/repository/private-executor-rbac-inventory-20260919/rbac-plan-only-c788681-gzip/execution`.

The [source renderer](../../scripts/render-staging-foundation-rbac.ps1) derives exactly three objects from the current staging Kustomize source: Namespace `oficina-staging`, Role `oficina-release-deployer`, and its same-named RoleBinding for the exact APP staging IAM-ARN User. The Namespace keeps exactly the four existing labels: `oficina.io/environment=staging` and Pod Security `enforce/audit/warn=restricted`. No annotations or new metadata are invented. The two RBAC objects are byte-identical to the earlier reviewed [RBAC-only candidate](../staging-missing-rbac/README.md). Production and existing identities remain unchanged.

| Artifact | SHA256 |
|---|---|
| [Three-object bundle](staging-foundation-rbac.json) | `ef27b26408a1e61fd11f3d5843377f86d6baa38e8ff6f032728acf2c8ea5e3b1` |
| [Namespace only](staging-namespace.json) | `9eb0ab9ce6cc8a782c0ce6010c40a5509a32f3b43f52a79121f64d53169eee9c` |
| [Unchanged RBAC](staging-release-rbac.json) | `c6376b4c5e4e9e65676612e0843334782806dbfb4b96963d1c14ffd75f2974ac` |

[foundation-candidate-plan.json](foundation-candidate-plan.json) is an offline proposed change inventory, not a live Terraform or three-create server plan. Raw Kustomize manifests own these resources; no Terraform root/state/provider is introduced.

The separately reviewable private plan-only payload is at `D:/repository/private-executor-rbac-inventory-20260919/staging-foundation-plan-only`. Payload SHA256 `761a0cb5186452c8d0acc14eb98f5cde5d8f144da406e8ca0da15ffd7ed8f1ae`; buildspec SHA256 `2ef4cc73680ab07f9a1ce0587b51dae37d5ef14cda220b1a1824bb9022a3b4cb`, 19,283 bytes. Its README documents exact commands, compressed/decoded hashes, fresh preflight requirements and rollback preconditions. No build was started by this change.

When Namespace is absent, the helper server-dry-runs only that Namespace and reports `PLAN_NAMESPACE_CREATE_RBAC_BLOCKED`: dry-run does not persist it, so RBAC validation remains blocked. An Active namespace with matching source labels permits RBAC reads and all-three server dry-run. Existing matching resources produce no-op; drift, partial state, malformed/null responses and failed commands stop. There is no persistent mutation path. The previous cloud window expired at 2026-09-19T05:39:46.735Z; fresh reviewed window evidence is required before any future dispatch.

Rollback for plan-only execution is no-op. Future persistent rollback requires separate approval and UID/resourceVersion preconditions, deleting only objects actually created by that approved run. Namespace deletion additionally requires proof that no other resources would be cascaded; controllers may create default namespace objects. Never delete an existing/reused Namespace or infer emptiness from this candidate.

Validation: [renderer tests](../../tests/staging-foundation-rbac-candidate-tests.ps1), 14 offline assertions; local plan helper and compressed wrapper, 121 assertions each across 15 mocked scenarios; compressed integrity/length tests. The renderer tests caught and fixed a Namespace-only array-wrapping serialization issue. No AWS/native kubectl runs in mocked executor tests; renderer invokes only local Kustomize and provider-free Terraform YAML decoding. No R4, submission or runtime readiness claim changes.
