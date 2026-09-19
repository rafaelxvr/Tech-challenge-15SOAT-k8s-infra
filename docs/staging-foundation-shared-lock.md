# Staging foundation shared-lock policy candidate

Review-only source change; no AWS commands, Terraform apply, CodeBuild dispatch, or production changes were performed.

## Evidence and scope

The merged K8S source `2c863ed6eaa0b3cae9bd05c84b21da0828b24e7c` already contains `SharedStagingPrerequisitesLock`, granting GetObject/PutObject/DeleteObject on the exact shared-lock object. This candidate tightens that existing grant; it is not evidence that the live role has been reconciled.

Diagnostic build `oficina-phase3-foundation-addons:3c623a67-7b81-444c-b0b9-05d86c459b41` succeeded, but its lock HEAD returned 403. The local receipt `D:/repository/staging-lock-readonly-diagnostic-execution-20260919/execution-receipt.json` has SHA256 `e6bb1e338c9bd79601ba534fe44fa038de5fcb18b80d4beff6d99f9a1d8e9e97`. GetRole and SimulatePrincipalPolicy also returned AccessDenied. Original lock acquisition stderr was discarded, so the original PutObject outcome/cause is unproven.

[S3 HEAD documentation](https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadObject.html) explains that an absent key can return 403 when ListBucket is unavailable. Do not treat this HEAD result as proof of missing GetObject, a held lock, or a successful PutObject. No bucket-wide listing is added to improve diagnostic output.

## Exact runtime permissions

The only changed role policy is `module.foundation_addons_executor.aws_iam_role_policy.foundation_addons`, named `foundation-addons-only`, for the existing foundation executor. The staging review target is role `oficina-phase3-foundation-addons-role` in account `638612472889`. Every new statement uses exactly `arn:aws:s3:::oficina-phase3-state-16225b7358/deployment-locks/shared-foundation.json` when rendered with the reviewed state bucket.

| Helper operation | IAM action | Restriction |
| --- | --- | --- |
| Acquire: PutObject | s3:PutObject | StringEquals s3:if-none-match = `*`; replacement is not allowed by this grant |
| Release: HEAD | s3:GetObject | Exact current lock object only; no version reads |
| Release: DeleteObject | s3:DeleteObject | If-Match must be present and must not be `*` |

`scripts/deployment-lock.ps1` checks owner metadata and uses the ETag from that same HEAD for the conditional delete. IAM conditions do not independently prove owner-token equality; that remains the helper's responsibility. The [conditional-delete documentation](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-delete-enforce.html) requires GetObject alongside DeleteObject for a specific ETag. No DeleteObjectVersion is granted; historical versions remain recoverable.

The existing bootstrap state bucket uses SSE-S3 (`AES256`) and denies insecure transport. No KMS grant or bucket policy change is needed for that contract. Before any live reconciliation, verify bucket encryption, boundary/SCP/bucket/VPC-endpoint policies and the current role policy with an already authorized reviewer identity. If encryption is actually SSE-KMS, stop and review the exact key/policy separately; do not invent a KMS ARN or add wildcard permissions.

`iam:GetRole` and `iam:SimulatePrincipalPolicy` are diagnostic-only. The runtime helper needs neither, so this candidate grants neither. It adds no Secrets Manager, Kubernetes, production executor, EKS access-entry, trust-policy, source/buildspec, or resource changes. The existing shared foundation lock coordinates operations; a lock permission itself is not staging deployment authorization. Existing staging payload/window gates remain mandatory, and production must remain disabled.

## Offline checks and later plan gate

Run from repository root:

```powershell
terraform -chdir=infra/modules/foundation-addons-executor test -no-color
terraform -chdir=infra/modules/foundation-addons-executor validate -no-color
./infra/modules/foundation-addons-executor/tests/executor-contract.ps1
git diff --check
```

RED: the updated mocked Terraform assertion failed against the old unconditional three-action statement (1 passed, 1 failed). GREEN: 2 mocked plan runs passed, 0 failed. Assertions require the exact three statements/conditions/resource, preserve existing log scope and ListBucket prefixes, and reject new diagnostic IAM/KMS/state-version grants. Existing PowerShell executor contract and Terraform validate passed. Provider initialization used the existing local AWS 5.100.0 mirror; no AWS credentials or APIs were used, and committed provider lock bytes were unchanged.

No real backend plan was run. A later separately authorized plan must permit only an in-place update to `module.foundation_addons_executor.aws_iam_role_policy.foundation_addons` (0 creates, 1 update, 0 deletes), with these three lock statements as the only policy delta. Reject unrelated statements, project/buildspec changes, production resources, role recreation, or any other address. If live policy already has the candidate bytes, require zero changes. Mocked plans validate policy rendering, not the actual cloud delta.

Before any eventual apply, retain the exact current live inline policy and state VersionId/hash, verify policy drift, and use the reviewed plan/window/lock process. Rollback would restore only that captured inline-policy document after confirming its candidate hash and no active lock/build; it requires separate authorization. Do not restore a guessed or historical policy, delete the role, or retry the installer as part of this candidate.
