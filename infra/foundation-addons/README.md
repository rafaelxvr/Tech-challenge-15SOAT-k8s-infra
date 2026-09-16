# Foundation addons

This root owns only the four pinned cluster-wide Helm releases: AWS Load Balancer Controller, metrics-server, Secrets Store CSI Driver, and the AWS provider. Its state is `foundation-addons/terraform.tfstate`; its private executor owns the matching `.tflock` only.

Foundation creates the executor, its VPC attachment, and EKS access entry. The executor reads `foundation-addons/bundle.zip` from the reviewed artifact bucket, writes generated nonsecret connection inputs locally, then validates, plans, and applies this root through the private cluster endpoint. It uses the pinned shared deployer image.

For an existing deployment, migrate the four `helm_release` state addresses from the Foundation state into this root during an approved maintenance window before triggering the executor. Do not run both roots against the same releases.

1. Stop the `deploy-foundation-addons` workflow and any Foundation apply. Take versioned S3 backup copies of both state objects, then confirm the old state has exactly these addresses:

   ```powershell
   terraform -chdir=infra/foundation state list | Select-String '^helm_release\.(aws_load_balancer_controller|metrics_server|secrets_store_csi_driver|secrets_store_csi_aws_provider)$'
   terraform -chdir=infra/foundation-addons init -backend-config="bucket=<state-bucket>" -backend-config='key=foundation-addons/terraform.tfstate' -backend-config='region=us-east-1' -backend-config='use_lockfile=true'
   terraform -chdir=infra/foundation-addons state list
   ```

2. With both roots locked and no concurrent apply, move each address from the downloaded Foundation state to a local copy of the new state. Use `state mv` with `-state` and `-state-out`; do not use `terraform apply` to recreate an existing chart.

   ```powershell
   $addresses = @('helm_release.aws_load_balancer_controller','helm_release.metrics_server','helm_release.secrets_store_csi_driver','helm_release.secrets_store_csi_aws_provider')
   terraform -chdir=infra/foundation state pull | Set-Content .\foundation-before.tfstate -NoNewline
   terraform -chdir=infra/foundation-addons state pull | Set-Content .\foundation-addons-before.tfstate -NoNewline
   Copy-Item .\foundation-before.tfstate .\foundation-after.tfstate
   Copy-Item .\foundation-addons-before.tfstate .\foundation-addons-after.tfstate
   foreach ($address in $addresses) { terraform state mv -state=.\foundation-after.tfstate -state-out=.\foundation-addons-after.tfstate $address $address }
   terraform -chdir=infra/foundation state push .\foundation-after.tfstate
   terraform -chdir=infra/foundation-addons state push .\foundation-addons-after.tfstate
   ```

3. Verify the old root has no `helm_release` addresses and the new root has all four. Run `terraform plan` in both roots; each must show no chart create/delete. Only then allow one staging launch. If a check fails before the first addons apply, stop the workflow and restore both saved state versions with `terraform state push`; do not import or recreate charts while either state can still own an address.
