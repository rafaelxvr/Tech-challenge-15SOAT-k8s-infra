# Protected state and OIDC bootstrap

Run these commands only during the approved cloud window, from a dedicated MFA-protected IAM human identity. The input checker calls STS to confirm that identity but does not print credentials or account values. Do not use the AWS root user, fixed GitHub credentials, or `terraform apply` from a pull-request job.

1. Copy the approved, secret-free deployment-input JSON to a local ignored path and validate it.

   ```powershell
   $inputs = 'C:\secure\phase3-deployment-inputs.json'
   .\scripts\check-deployment-inputs.ps1 -InputFile $inputs
   ```

2. Generate a complete local Terraform variables file from the validated inputs. The generated JSON has every variable required by `infra/bootstrap`, including launcher mappings and dedicated state keys; it contains no access keys or secret values.

   ```powershell
   $tfvars = 'C:\secure\phase3-bootstrap.tfvars.json'
   .\scripts\new-bootstrap-tfvars.ps1 -InputFile $inputs -OutputFile $tfvars
   Get-Content -Raw -LiteralPath $tfvars | ConvertFrom-Json | Format-List
   ```

   The input file must already contain the reviewed repository/environment records. Configure GitHub's `staging` environment to allow `develop` and its `production` environment to allow `main`; PR workflows do not receive `id-token: write` or an AWS role. Each staging record must use `develop`; each production record must use `main`. The trusted subject is exactly `repo:OWNER/REPOSITORY:environment:staging` or `...:production`, and never a pull-request subject.

3. Review local configuration without creating resources, then run the one-time bootstrap only after the cloud-window and human approval checks pass.

   ```powershell
   terraform -chdir=infra/bootstrap init -backend=false
   terraform -chdir=infra/bootstrap validate
   terraform -chdir=infra/bootstrap plan -out=bootstrap.tfplan -var-file=$tfvars
   # Approved cloud-window action only: terraform -chdir=infra/bootstrap apply bootstrap.tfplan
   ```

4. After the state bucket exists, migrate the local bootstrap state to its dedicated S3 key with S3 native locking. Substitute only values read from the validated input file.

   ```powershell
   terraform -chdir=infra/bootstrap init -migrate-state `
     -backend-config="bucket=$($input.stateBucketName)" `
     -backend-config='key=bootstrap/terraform.tfstate' `
     -backend-config="region=$($input.region)" `
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
