# Staging APP executor identity mapping candidate

**REVIEW ONLY — NOT APPLIED. Live namespace RBAC verification remains blocked.** No access entry, Role, RoleBinding, IAM permission, or CodeBuild retry was created while preparing this candidate.

APP build `oficina-phase3-oficina-app-staging-deploy:02a7fcb8-2194-4327-b067-029ac8ffebde` failed on 2026-09-19. EKS authenticator records prove the correct AWS role/session reached the private API and was rejected with `identity is not mapped`. The APP role is absent from EKS access entries. Read-only evidence and hashes are retained at `D:/repository/app-staging-activation-artifacts-8e9cba5/kubectl-failure-diagnosis.md` and `diagnostic-hashes.json`. No deployment success or R4 acceptance is claimed.

## Durable ownership

The existing platform access entry continues to represent the K8S executor. The staging root now supplies the distinct `foundation_outputs.codebuild_projects["app_staging"].roleArn` to a nullable module input. That input accepts only the exact same-account `oficina-phase3-oficina-app-staging-deploy-role`, only in staging. Production does not set the input, so its behavior is unchanged.

The new Terraform address is `module.platform.aws_eks_access_entry.app_deployer[0]`. It creates a STANDARD entry with `user_name` equal to the literal IAM role ARN, matching the `kind: User` subject in the existing rendered `oficina-release-deployer` RoleBinding. Default EKS role usernames use an STS session ARN and would not match that User. There are no Kubernetes groups or EKS access-policy associations; authorization stays in namespace RBAC. This is not a grant of cluster administrator access.

## Live read blocker and required evidence

The existing local `oficina-staging` context points directly at the private EKS endpoint, with no proxy. A bounded read on 2026-09-19 failed during API discovery with timeout; `rolebinding-local-read-attempt.json` records the exact command, timestamp and exit status. `active-private-sessions.json` contains an empty SSM active-session inventory; no existing SSH/session-manager/VPN process was found. No diagnostic CodeBuild run or new SSM session was started to bypass the pause.

Using an already authorized private path, an operator must save these read-only results before any candidate apply:

```powershell
kubectl --context <already-authorized-private-context> --namespace oficina-staging get rolebinding oficina-release-deployer -o json
kubectl --context <already-authorized-private-context> --namespace oficina-staging get role oficina-release-deployer -o json
```

Verify both objects are in `oficina-staging`, the RoleBinding references the namespaced Role `oficina-release-deployer`, and its User subject is exactly `arn:aws:iam::638612472889:role/oficina-phase3-oficina-app-staging-deploy-role`. Compare Role rules with the merged staging overlay, including only the reviewed ServiceAccount/Job/HPA permissions. Reject extra subjects, wildcard grants, production namespaces, missing rules, or unexpected drift. Do not grant APP inspection privileges merely to obtain this evidence. Until these reads succeed, namespace authorization is **unverified**, and the candidate is not ready to apply.

## Drift, apply boundary and rollback

1. Recheck AWS account `638612472889`, region `us-east-1`, cluster `oficina-phase3`, exact role ARN, and absence of an active APP staging build. Refresh DescribeAccessEntry: if the APP entry now exists, stop to review its username, groups and associations rather than overwrite or duplicate it. Preserve the existing K8S executor entry. Do not read secret values.
2. After separate approval and live RBAC verification, render a saved Terraform plan against the reviewed staging state `environments/staging.tfstate`. Require exactly one access-entry creation and no unrelated change; stop on production, IAM, gateway, target-group, Role or RoleBinding changes. Do not apply the whole root merely because mocked tests pass. `docs/staging-app-access-entry/create-candidate.json` records the expected nonsecret AWS shape, not an executed CLI workaround.
3. If a separately approved operator already creates the exact entry, import it into `module.platform.aws_eks_access_entry.app_deployer[0]` using ID `oficina-phase3:arn:aws:iam::638612472889:role/oficina-phase3-oficina-app-staging-deploy-role`, then require a no-change plan. Never maintain a duplicate unmanaged entry.
4. Post-apply, DescribeAccessEntry must show exact principal/username, STANDARD type and no groups; ListAssociatedAccessPolicies must remain empty. Capture timestamped responses and SHA256. Re-read the namespace binding before any separately authorized rollout. Mapping alone is not rollout acceptance.
5. Rollback removes only this candidate's staging root input (module default null), then reviews a saved plan deleting only `module.platform.aws_eks_access_entry.app_deployer[0]`. Do not roll back while a build is active. `rollback-candidate.json` pins the deletion identity for comparison; if emergency CLI deletion is separately approved, reconcile Terraform afterward. Preserve the K8S executor entry, all production access, and namespace resources. Rollback does not undo workload/database changes.

## Offline validation

The new PowerShell contract failed RED with `Separate APP access entry is missing`, then passed after implementation. Module mocked tests cover absent default, exact identity/username, unchanged K8S executor, production default, explicit production rejection, cross-account rejection and wrong-repository rejection. Run:

```powershell
pwsh -NoProfile -File tests/staging-app-access-entry-contract.ps1
terraform -chdir=infra/modules/platform-environment test -no-color
terraform -chdir=infra/environments/staging test -no-color
terraform fmt -check -recursive infra/modules/platform-environment infra/environments/staging
git diff --check
```

Provider initialization uses the existing lockfiles with `-backend=false -lockfile=readonly`. These tests do not authenticate to AWS or prove live RoleBinding contents.
