locals {
  state_key         = "foundation-addons/terraform.tfstate"
  source_key        = "foundation-addons/bundle.zip"
  project_name      = "${var.name}-foundation-addons"
  role_name         = "${local.project_name}-role"
  cluster_admin_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  codebuild_vpc_network_interface_actions = [
    "ec2:CreateNetworkInterface",
    "ec2:DescribeDhcpOptions",
    "ec2:DescribeNetworkInterfaces",
    "ec2:DeleteNetworkInterface",
    "ec2:DescribeSubnets",
    "ec2:DescribeSecurityGroups",
    "ec2:DescribeVpcs"
  ]
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "codebuild.amazonaws.com" } }]
  })
  generated_tfvars = jsonencode({
    aws_region                        = var.aws_region
    cluster_name                      = var.cluster_name
    cluster_endpoint                  = var.cluster_endpoint
    cluster_ca_certificate            = var.cluster_ca_certificate
    vpc_id                            = var.vpc_id_for_controller
    load_balancer_controller_role_arn = var.load_balancer_controller_role_arn
  })
  buildspec = <<-YAML
    version: 0.2
    phases:
      build:
        commands:
          - set -euo pipefail
          - required=(ADDONS_SOURCE_BUCKET ADDONS_SOURCE_KEY ADDONS_SOURCE_VERSION_ID ADDONS_EXPECTED_SHA256 ADDONS_MANIFEST_KEY ADDONS_MANIFEST_VERSION_ID ADDONS_EXPECTED_MANIFEST_SHA256 ADDONS_SOURCE_COMMIT)
          - for variable in "$${required[@]}"; do test -n "$${!variable:-}" || { echo "Missing reviewed addon input: $${variable}"; exit 1; }; done
          - workdir="$$(mktemp -d)"; export WORKDIR="$${workdir}"; trap 'rm -rf "$${workdir}"' EXIT
          - aws s3api get-object --bucket "$${ADDONS_SOURCE_BUCKET}" --key "$${ADDONS_SOURCE_KEY}" --version-id "$${ADDONS_SOURCE_VERSION_ID}" "$${workdir}/bundle.zip" >/dev/null
          - test "$$(sha256sum "$${workdir}/bundle.zip" | awk '{print $1}')" = "$${ADDONS_EXPECTED_SHA256}"
          - aws s3api get-object --bucket "$${ADDONS_SOURCE_BUCKET}" --key "$${ADDONS_MANIFEST_KEY}" --version-id "$${ADDONS_MANIFEST_VERSION_ID}" "$${workdir}/manifest.json" >/dev/null
          - test "$$(sha256sum "$${workdir}/manifest.json" | awk '{print $1}')" = "$${ADDONS_EXPECTED_MANIFEST_SHA256}"
          - pwsh -NoLogo -NoProfile -Command '$m=Get-Content -Raw "$env:WORKDIR/manifest.json" | ConvertFrom-Json; if ($m.schemaVersion -ne 1 -or $m.sourceCommit -cne $env:ADDONS_SOURCE_COMMIT -or $m.artifactSha256 -cne $env:ADDONS_EXPECTED_SHA256) { throw "Foundation addons manifest does not bind the source." }'
          - unzip -q "$${workdir}/bundle.zip" -d "$${workdir}/release"
          - test -f "$${workdir}/release/infra/foundation-addons/main.tf"
          - cd "$${workdir}/release/infra/foundation-addons"
          - cat > foundation-addons.auto.tfvars.json <<'TFVARS'
            ${local.generated_tfvars}
            TFVARS
          - terraform init -input=false -backend-config="bucket=${var.state_bucket_name}" -backend-config="key=${local.state_key}" -backend-config="region=${var.aws_region}" -backend-config="use_lockfile=true"
          - terraform validate
          - terraform plan -input=false -lock-timeout=5m -out=foundation-addons.tfplan
          - terraform apply -input=false -auto-approve foundation-addons.tfplan
  YAML
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ReadOnlyFoundationAddonsBundle", Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion"], Resource = ["arn:aws:s3:::${var.artifact_bucket_name}/${local.source_key}", "arn:aws:s3:::${var.artifact_bucket_name}/foundation-addons/manifests/*"] },
      { Sid = "ListOnlyFoundationAddonsState", Effect = "Allow", Action = "s3:ListBucket", Resource = "arn:aws:s3:::${var.state_bucket_name}", Condition = { StringLike = { "s3:prefix" = [local.state_key, "${local.state_key}.tflock"] } } },
      { Sid = "ReadWriteOnlyFoundationAddonsState", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = "arn:aws:s3:::${var.state_bucket_name}/${local.state_key}" },
      { Sid = "LockOnlyFoundationAddonsState", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "arn:aws:s3:::${var.state_bucket_name}/${local.state_key}.tflock" },
      { Sid = "DescribeOnlyPrivateCluster", Effect = "Allow", Action = "eks:DescribeCluster", Resource = var.cluster_arn },
      { Sid = "CodeBuildVpcNetworkInterfaces", Effect = "Allow", Action = local.codebuild_vpc_network_interface_actions, Resource = "*" },
      {
        Sid      = "CodeBuildVpcNetworkInterfacePermission"
        Effect   = "Allow"
        Action   = "ec2:CreateNetworkInterfacePermission"
        Resource = "arn:aws:ec2:${var.aws_region}:${var.account_id}:network-interface/*"
        Condition = {
          StringEquals = { "ec2:AuthorizedService" = "codebuild.amazonaws.com" }
          ArnEquals    = { "ec2:Subnet" = [for subnet in var.private_subnet_ids : "arn:aws:ec2:${var.aws_region}:${var.account_id}:subnet/${subnet}"] }
        }
      },
      { Sid = "PullOnlyPinnedDeployerImage", Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], Resource = "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/${split("/", var.deployer_repository_url)[1]}" },
      { Sid = "AuthenticateOnlyToPullDeployerImage", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      { Sid = "CreateOnlyThisBuildLogGroup", Effect = "Allow", Action = "logs:CreateLogGroup", Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/codebuild/${local.project_name}" },
      { Sid = "WriteOnlyThisBuildLogGroup", Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/codebuild/${local.project_name}:log-stream:*" }
    ]
  })
}

resource "aws_iam_role" "foundation_addons" {
  name               = local.role_name
  assume_role_policy = local.assume_role_policy
}

resource "aws_iam_role_policy" "foundation_addons" {
  name   = "foundation-addons-only"
  role   = aws_iam_role.foundation_addons.id
  policy = local.policy
}

# The dedicated executor receives a cluster-scoped EKS policy because the four
# reviewed charts create kube-system and cluster-scoped resources. It receives
# no IAM/EKS write permission. Required VPC interfaces and its own build logs
# accompany the writes to its isolated Terraform state and lock.
resource "aws_eks_access_entry" "foundation_addons" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.foundation_addons.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "foundation_addons" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.foundation_addons.arn
  policy_arn    = local.cluster_admin_arn
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.foundation_addons]
}

resource "aws_codebuild_project" "foundation_addons" {
  name                   = local.project_name
  description            = "Private executor for the reviewed foundation Helm addons only."
  service_role           = aws_iam_role.foundation_addons.arn
  build_timeout          = 30
  queued_timeout         = 30
  concurrent_build_limit = 1
  artifacts { type = "NO_ARTIFACTS" }
  source {
    type      = "S3"
    location  = "${var.artifact_bucket_name}/${local.source_key}"
    buildspec = local.buildspec
  }
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "${var.deployer_repository_url}@${var.deployer_image_digest}"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "SERVICE_ROLE"
    privileged_mode             = false
  }
  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = var.private_subnet_ids
    security_group_ids = var.security_group_ids
  }
  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${local.project_name}"
      stream_name = "apply"
    }
  }
  depends_on = [aws_iam_role_policy.foundation_addons, aws_eks_access_policy_association.foundation_addons]
}
