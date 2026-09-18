# Reviewed deployment sequence

The YAML in this repository is a release mechanism, not a substitute for GitHub protection rules. Before a cloud run, repository owners configure `develop` and `main` with required pull requests, reviews and checks; configure the `staging` environment for `develop` and the `production` environment for `main`; and assign the exact launcher role, artifact prefix, executor project, deployer image digest and time-bounded account-evidence secret to the matching protected environment. These settings are external prerequisites and are deliberately absent from source control.

1. A pull request runs local contracts and Terraform formatting with `contents: read` only. It has no `id-token: write` permission and cannot start a deployment.
2. A push to `develop` enters the `staging` GitHub environment. A push to `main` enters `production`; its release manifest must name the reviewed staging manifest SHA-256 **and** match its staged artifact SHA-256. A content-changing production merge therefore returns through staging before its promotion evidence is set.
3. After a reviewed foundation apply, its separate publisher identity runs `scripts/publish-foundation-outputs.ps1`; it exports the foundation allowlist and writes `releases/k8s/foundation/outputs/{sourceCommit}.json`, retaining its S3 VersionId/SHA-256 receipt. A platform launcher reads that protected receipt, runs `scripts/resolve-foundation-outputs.ps1` to fetch the exact version and verify its digest/schema/environment/source commit, and only then merges the resulting `foundation_outputs` into a base tfvars file that did not supply them. The launcher assumes only its environment OIDC role, builds a Git archive at the reviewed commit, hashes it, creates a non-secret release manifest, validates the current cloud-window evidence, writes both objects and the resulting hashed Terraform-input JSON to its exact S3 prefix, and starts the exact CodeBuild project with the returned object VersionIds.
4. The private executor does not trust the archive-owned buildspec. Terraform renders each executor's environment, backend bucket, state key, derived lock key, backend region, deployment mode, and Terraform-input path as literals in its Terraform-owned inline bootstrap; none is a CodeBuild project environment variable. The launcher IAM role denies `buildspecOverride` and environment-variable overrides for `DEPLOYMENT_MODE` and `DEPLOYMENT_TFVARS_PATH`, so a start request cannot replace or alter those literals. The bootstrap rejects an environment override that differs from its literal, downloads the specified bundle, manifest and Terraform-input versions again, validates all three hashes, and rejects a lock key that is not derived from the state key. The environment roots declare the S3 backend and native lockfile support. The bootstrap invokes `scripts/deploy.ps1`, which accepts only `environments/{environment}.tfstate`, initializes S3 with that bucket/key/region and `use_lockfile=true`, then validates the environment, commit, contract/migration versions and immutable deployer image digest before Terraform can plan. The CodeBuild service role is the Terraform provider principal; it does not assume a broader deployment role. Each executor has only its own state object and `.tflock` permissions, plus the limited EKS/API Gateway/ELB provider actions required by the Kubernetes environment root. `DEPLOYMENT_MODE=apply` is an explicit reviewed Terraform value; all other approved preparation runs use `plan`.
5. After a staging CodeBuild job reaches `SUCCEEDED`, its staging launcher writes an immutable promotion attestation containing the exact source version, manifest version/hash and build identity. A production launcher has read access only to its same-repository staging attestation and manifest prefixes. It retrieves both named S3 versions, verifies their SHA-256 values and matching successful-build provenance, then writes the local verified-promotion document required by the production launcher. The production release manifest carries the receipt SHA-256, S3 key and S3 VersionId, and launch requires all three to match that verified document exactly. A manually entered manifest SHA cannot authorize promotion.
6. Shared foundation changes pass `-SharedFoundationMutation` and acquire `deployment-locks/shared-foundation.json` in the existing state bucket using S3 conditional create. A second owner cannot replace it, and release checks the owner token before deleting it. State locking remains per Terraform root; this separate lock coordinates cross-root work.

Run local proof before review:

```powershell
pwsh ./tests/pipeline-contract.ps1
pwsh ./tests/release-readiness-contract.ps1
terraform fmt -check -recursive
```

The eight real repository/environment launches, branch-protection screenshots, environment-policy evidence, cloud-window evidence and deployment outcomes are R4 acceptance artifacts. Do not run `terraform apply`, set repository visibility, alter GitHub permissions, or start a deployment until the reviewed artifacts and explicit authorization are available.

## I7 source hardening

### APP staging source-prefix input

The platform owns `infra/foundation`'s reviewed `deployments` input and the
`deployment-executor` module. For the entry whose repository is `oficina-app`
and environment is `staging`, set `source_prefix = "releases/app/staging"`.
The module derives both CodeBuild's S3 source location
`<artifact-bucket>/releases/app/staging/bundle.zip` and its exact source-prefix
read policy from that single input. A legacy `releases/application/staging`
value fails validation; changing only CodeBuild's location would leave IAM
inconsistent. Map keys are input-specific; select the entry by repository and
environment rather than assuming its key.

If an existing project has the legacy location, the platform owner must correct
the external reviewed foundation input and review the resulting project/policy
plan through the existing cloud-window and apply guards. Separately verify that
the bootstrap launcher's reviewed `sourcePrefix` and APP workflow source prefix
are also `releases/app/staging`. The bootstrap input writer emits launcher
permissions, not the foundation `deployments` map. This source change does not
edit private inputs or apply cloud changes; production inputs, deployment mode,
and authorization remain unchanged. Offline regression coverage lives in
`infra/modules/deployment-executor/tests/app-source-prefix.tftest.hcl`.

Before any OIDC request, each deployment job independently checks its exact push/branch/environment context with `check-workflow-context.ps1`. PRs, tags, manual dispatch and legacy master cannot pass that guard. Non-cancelling environment concurrency, named S3 object versions, checksum bootstrap, terminal CodeBuild polling and staging promotion receipt verification remain required.

`package-source.ps1` resolves the reviewed commit to its tree and uses a fixed archive timestamp. Tests prove that an unchanged merge preserves artifact bytes and a changed tree produces a different digest. Production still requires the successful immutable staging receipt; deterministic packaging does not waive that proof. The package helper never archives the mutable working directory.

Record actual repository visibility, immutable OIDC subject, branch ruleset/protection IDs, required checks/reviews and restricted bypass, plus develop-only staging and main-only production environment policies during external setup. Source changes neither configure those protections nor authorize production. The APP/FUN cloud adapters remain separately fail-closed pending their documented migration/ownership and execution prerequisites; I7 across all four owners is therefore partial, not evidence of eight successful cloud deployments.

Run `tests/source-package-contract.ps1`, `tests/workflow-context-contract.ps1` and the existing pipeline contract suite. Output tests reject sensitive allowlisted fields in addition to filtering unknown credentials/state fields. No AWS API call or cloud deployment is needed for these local proofs.

Lock release checks the owner and observed ETag from the same HEAD, then sends `DeleteObject --if-match` with that exact ETag. A replacement owner changes the lock payload; S3 rejects the stale conditional delete. Missing/wildcard ETags and every delete failure stop release without retrying unconditionally. No specific object version is permanently deleted. The executor AWS CLI must support [S3 DeleteObject If-Match](https://docs.aws.amazon.com/cli/latest/reference/s3api/delete-object.html); an older CLI fails closed and must be updated in its separate reviewed image release. Offline lock mutations use a shared named mutex around owner comparison/deletion. `tests/deployment-lock-race-contract.ps1` deterministically replaces owner A with B between HEAD and DELETE and proves B survives; the old implementation fails this test. AWS calls in this proof are mocked.

The K8S deployer source now pins AWS CLI 2.36.42, whose DeleteObject command supports `--if-match` on the general-purpose state bucket. Rebuild and review that image's immutable digest before activating these scripts; existing executors pinned to the old 2.17.62 image will fail closed on release. This source fix does not rebuild, push or roll out an image.
