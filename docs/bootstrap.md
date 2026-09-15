# Protected state and OIDC bootstrap

Run these commands only during the approved cloud window, from a dedicated MFA-protected IAM human identity. The input checker calls STS to confirm that identity but does not print credentials or account values. Do not use the AWS root user, fixed GitHub credentials, or `terraform apply` from a pull-request job.

1. Copy the approved, secret-free deployment-input JSON to a local ignored path and validate it.

   ```powershell
   $inputs = 'C:\secure\phase3-deployment-inputs.json'
   .\scripts\check-deployment-inputs.ps1 -InputFile $inputs
   ```

2. Convert only validated values into a local ignored Terraform variables file. There are no access keys or secret values in this file.

   ```powershell
   $input = Get-Content -Raw -LiteralPath $inputs | ConvertFrom-Json
   @{
     aws_region               = $input.region
     account_id               = $input.accountId
     state_bucket_name        = $input.stateBucketName
     artifact_bucket_name     = $input.artifactBucketName
     github_oidc_provider_arn = $input.githubOidcProviderArn
     state_keys = @{ bootstrap = 'bootstrap/terraform.tfstate'; foundation = 'foundation/terraform.tfstate'; staging = 'environments/staging/terraform.tfstate'; production = 'environments/production/terraform.tfstate' }
     launchers = @{}
     runtime_role_arns = []
   } | Out-Null
   ```

   Populate `launchers` from the validated repository/environment records before review. Configure GitHub's `staging` environment to allow `develop` and its `production` environment to allow `main`; PR workflows do not receive `id-token: write` or an AWS role. Each staging record must use `develop`; each production record must use `main`. The trusted subject is exactly `repo:OWNER/REPOSITORY:environment:staging` or `...:production`, and never a pull-request subject.

3. Review local configuration without creating resources, then run the one-time bootstrap only after the cloud-window and human approval checks pass.

   ```powershell
   terraform -chdir=infra/bootstrap init -backend=false
   terraform -chdir=infra/bootstrap validate
   terraform -chdir=infra/bootstrap plan -out=bootstrap.tfplan -var-file=C:\secure\phase3-bootstrap.tfvars
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
