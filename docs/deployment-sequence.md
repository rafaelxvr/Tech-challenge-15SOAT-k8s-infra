# Reviewed deployment sequence

The YAML in this repository is a release mechanism, not a substitute for GitHub protection rules. Before a cloud run, repository owners configure `develop` and `main` with required pull requests, reviews and checks; configure the `staging` environment for `develop` and the `production` environment for `main`; and assign the exact launcher role, artifact prefix, executor project, deployer image digest and time-bounded account-evidence secret to the matching protected environment. These settings are external prerequisites and are deliberately absent from source control.

1. A pull request runs local contracts and Terraform formatting with `contents: read` only. It has no `id-token: write` permission and cannot start a deployment.
2. A push to `develop` enters the `staging` GitHub environment. A push to `main` enters `production`; its release manifest must name the reviewed staging manifest SHA-256 **and** match its staged artifact SHA-256. A content-changing production merge therefore returns through staging before its promotion evidence is set.
3. The GitHub launcher assumes only its environment OIDC role, builds a Git archive at the reviewed commit, hashes it, creates a non-secret release manifest, validates the current cloud-window evidence, writes both objects to their exact S3 prefix, and starts the exact CodeBuild project with the returned object VersionIds.
4. The private executor does not trust the archive-owned buildspec. Its Terraform-owned inline bootstrap downloads the specified bundle and manifest versions again, validates both hashes, then invokes `scripts/deploy.ps1`. The script validates the environment, commit, contract/migration versions and immutable deployer image digest before Terraform can plan. `DEPLOYMENT_MODE=apply` is an explicit reviewed executor configuration; all other approved preparation runs use `plan`.
5. Shared foundation changes pass `-SharedFoundationMutation` and acquire `deployment-locks/shared-foundation.json` in the existing state bucket using S3 conditional create. A second owner cannot replace it, and release checks the owner token before deleting it. State locking remains per Terraform root; this separate lock coordinates cross-root work.

Run local proof before review:

```powershell
pwsh ./tests/pipeline-contract.ps1
terraform fmt -check -recursive
```

The eight real repository/environment launches, branch-protection screenshots, environment-policy evidence, cloud-window evidence and deployment outcomes are R4 acceptance artifacts. Do not run `terraform apply`, set repository visibility, alter GitHub permissions, or start a deployment until the reviewed artifacts and explicit authorization are available.
