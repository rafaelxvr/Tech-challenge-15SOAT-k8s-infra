# Protected state and OIDC bootstrap

Run these commands only during the approved cloud window, from a dedicated MFA-protected IAM human identity. The input checker resolves AWS CLI v2 from `OFICINA_AWS_CLI_PATH`, then `PATH`, then `C:\Program Files\Amazon\AWSCLIV2\aws.exe`; it calls STS to confirm the identity but does not print credentials or account values. If none resolve, it stops before invoking a shell command. Do not use the AWS root user, fixed GitHub credentials, or `terraform apply` from a pull-request job.

1. Copy the approved, secret-free deployment-input JSON to a local ignored path and validate it.

   ```powershell
   $inputs = 'C:\secure\phase3-deployment-inputs.json'
   .\scripts\check-deployment-inputs.ps1 -InputFile $inputs
   ```

   The checker rejects the AWS root identity by default, including when STS reports root. A narrowly bounded study exception is available only for a staging-only input and only when a reviewer has created a **local, redacted** evidence record beside that input. It never permits production launchers and does not relax the GitHub OIDC subject checks. The exception justification is JSON with a Phase 3 staging scope, an operator-approved purpose that names validation/rehearsal/verification, and a bounded window reference. It must contain no account IDs, ARNs, credentials, tokens, or secrets. The input's `studyRootException.evidenceRecord` must name the sibling record; that record must have `APPROVED_FOR_STUDY_STAGING`, `staging`, a UTC `timestampUtc`, and the SHA-256 fingerprint, scope, and window from the exact justification string.

   ```powershell
   $studyReason = '{"studyScope":"phase-3-staging-bootstrap-study","operatorApprovedPurpose":"Validate the bounded staging bootstrap rehearsal.","boundedWindowReference":"window-bootstrap-20260916"}'
   .\scripts\check-deployment-inputs.ps1 -InputFile $inputs -AllowStudyRoot -StudyRootJustification $studyReason
   ```

   This switch is for the approved study record only. It fails for root without the switch, production or mixed launcher sets, vague or sensitive justifications, missing evidence, or a record whose fingerprint/scope/window does not exactly match. Do not copy the evidence record or justification into Terraform variables, a repository, CI logs, or an issue.

2. Generate a complete local Terraform variables file from the validated inputs. The generated JSON has every variable required by `infra/bootstrap`, including launcher mappings and dedicated state keys; it contains no access keys or secret values.

   ```powershell
   $tfvars = 'C:\secure\phase3-bootstrap.tfvars.json'
   .\scripts\new-bootstrap-tfvars.ps1 -InputFile $inputs -OutputFile $tfvars
   $written = Get-Content -Raw -LiteralPath $tfvars | ConvertFrom-Json
   $requiredKeys = @('aws_region', 'account_id', 'state_bucket_name', 'artifact_bucket_name', 'github_oidc_provider_arn', 'state_keys', 'launchers', 'runtime_role_arns')
   $missingKeys = $requiredKeys | Where-Object { $null -eq $written.PSObject.Properties[$_] }
   if ($missingKeys -or @($written.launchers.PSObject.Properties).Count -eq 0) { throw 'Generated Terraform variables are incomplete.' }
   Write-Output 'Bootstrap Terraform variable structure is complete.'
   ```

   The input file must already contain the reviewed repository/environment records. Configure GitHub's `staging` environment to allow `develop` and its `production` environment to allow `main`; PR workflows do not receive `id-token: write` or an AWS role. Each staging record must use `develop`; each production record must use `main`. Capture the reviewed repository OIDC API `sub_claim_prefix` with `use_immutable_subject: true` as the required `githubSubjectPrefix`, for example `repo:OWNER@OWNER_ID/REPOSITORY@REPOSITORY_ID`. Set `githubSubject` to that exact prefix plus `:environment:staging` or `:environment:production`. Both numeric IDs must be preserved; they are not inferred from repository names. The checker verifies prefix syntax, case-sensitive repository identity and the exact full subject; the writer carries `github_subject_prefix` to Terraform, which appends only the approved environment. IAM uses `StringEquals` for this subject and `aud=sts.amazonaws.com`. There is no legacy, wildcard or pull-request fallback. Existing reviewed input/tfvars files must explicitly add the API-captured prefix before reapplying bootstrap; do not invent IDs or change GitHub OIDC configuration to fit old trust.

3. Review local configuration without creating resources, then run the one-time bootstrap only after the cloud-window and human approval checks pass.

   ```powershell
   terraform -chdir=infra/bootstrap init -backend=false
   terraform -chdir=infra/bootstrap validate
   terraform -chdir=infra/bootstrap plan -out=bootstrap.tfplan -var-file=$tfvars
   # Approved cloud-window action only: terraform -chdir=infra/bootstrap apply bootstrap.tfplan
   ```

4. After the state bucket exists, migrate the local bootstrap state to its dedicated S3 key with S3 native locking. Substitute only values read from the validated input file.

   ```powershell
   $deployment = Get-Content -Raw -LiteralPath $inputs | ConvertFrom-Json
   terraform -chdir=infra/bootstrap init -migrate-state `
     -backend-config="bucket=$($deployment.stateBucketName)" `
     -backend-config='key=bootstrap/terraform.tfstate' `
     -backend-config="region=$($deployment.region)" `
     -backend-config='use_lockfile=true'
   ```

5. Attach only the exported per-root state policy to the dedicated operator/deployment identity. Each policy permits its `.tfstate` object and its matching `.tflock`, never arbitrary state deletion. GitHub launchers can upload only their source prefix and start only their CodeBuild project; workload runtime roles are created later and must remain separate.

Run offline checks before review:

```powershell
terraform -chdir=infra/modules/bootstrap init -backend=false
terraform -chdir=infra/modules/bootstrap test
terraform -chdir=infra/bootstrap init -backend=false
terraform -chdir=infra/bootstrap validate
terraform fmt -check -recursive
.\tests\check-deployment-inputs-tests.ps1
```
