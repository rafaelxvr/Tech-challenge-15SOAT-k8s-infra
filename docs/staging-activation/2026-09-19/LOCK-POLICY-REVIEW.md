# Staging APP shared lock permission review

Status: **PREPARED, NOT APPLIED**. The reviewed buildspec update succeeded; APP/bootstrap images were published. No CodeBuild build or S3 release-package upload has started.

Preflight found the sole inline policy on `oficina-phase3-oficina-app-staging-deploy-role` lacks shared lock access, with no attached managed policies. Read-only IAM simulation returned `implicitDeny` for GetObject, PutObject and DeleteObject on `arn:aws:s3:::oficina-phase3-state-16225b7358/deployment-locks/shared-foundation.json`. The original response is `lock-policy-before.json`; simulation is `lock-permission-simulation.json`.

The proposed update preserves every existing policy statement and appends exactly the two statements rendered from K8S `f0238321` `infra/modules/deployment-executor/main.tf`: `ReadAndReleaseApplicationSharedFoundationLock` and `AcquireApplicationSharedFoundationLockConditionally`. Only GetObject/DeleteObject and conditional PutObject are added, against one exact object. `s3:if-none-match = *` enforces atomic acquisition. There is no bucket listing, arbitrary state access, production role update, or secret permission change.

APP `8e9cba5` `scripts/deploy-app.ps1` acquires this lock before rollout. `scripts/deployment-lock.ps1` uses conditional PutObject, HeadObject (authorized by GetObject), owner metadata comparison, then ETag-conditional DeleteObject. The shared lock intentionally serializes shared-foundation mutations across environments; staging will therefore contend with another legitimate holder. This patch does not alter the lock key or bypass an existing lock. IAM grants DeleteObject; owner/ETag protection remains enforced by the reviewed script, not a new IAM condition.

## Review commands

Run `pwsh -NoProfile -File tests/staging-lock-policy-review.ps1` to verify exact staging role, policy, resource, actions, acquisition condition, unchanged existing statements, rollback and Terraform rendering. Check `lock-policy-hashes.json`. The test is credential-free and makes no mutation.

After separate approval, refresh `aws iam get-role-policy --role-name oficina-phase3-oficina-app-staging-deploy-role --policy-name bounded-deployment-executor --profile study-process --region us-east-1` and compare semantically with `lock-policy-before.json`; stop on drift. Recheck account identity and active APP staging builds. The reviewed mutation command would be `aws iam put-role-policy --profile study-process --region us-east-1 --cli-input-json file://docs/staging-activation/2026-09-19/put-role-policy.json`. This document does not run it.

Re-read the policy and compare exactly to `lock-policy-after.json`; run IAM simulation with the `s3:if-none-match` string context set to `*` for PutObject, and verify missing/wrong condition does not authorize acquisition. Keep nonsecret pre/post receipts. No other role is targeted. Rollback uses the same put-role-policy command with `rollback-role-policy.json`, restoring the complete prior document; stop on intervening policy drift, and do not remove lock permissions while a build holds the lock. Rollback does not delete or release a lock.

Package/runtime evidence remains pending. The local package is `D:/repository/app-staging-activation-artifacts-8e9cba5/ready-lf`; its separate hash inventory and publication receipts are retained outside Git. If review outlives its cloud window, create a new reviewed window and rebind the manifest hash before publication. Neither this policy patch nor image publication establishes R4 success.
