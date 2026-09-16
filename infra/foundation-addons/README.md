# Foundation addons

This root owns only the four pinned cluster-wide Helm releases: AWS Load Balancer Controller, metrics-server, Secrets Store CSI Driver, and the AWS provider. Its state is `foundation-addons/terraform.tfstate`; its private executor owns the matching `.tflock` only.

Foundation creates the executor, its VPC attachment, and EKS access entry. The executor reads `foundation-addons/bundle.zip` from the reviewed artifact bucket, writes generated nonsecret connection inputs locally, then validates, plans, and applies this root through the private cluster endpoint. It uses the pinned shared deployer image.

For an existing deployment, migrate the four `helm_release` state addresses from the Foundation state into this root during an approved maintenance window before triggering the executor. Do not run both roots against the same releases.
