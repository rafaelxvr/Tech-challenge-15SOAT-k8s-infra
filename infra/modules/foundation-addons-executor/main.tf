locals {
  state_key         = "foundation-addons/terraform.tfstate"
  source_key        = "foundation-addons/bundle.zip"
  project_name      = "${var.name}-foundation-addons"
  role_name         = "${local.project_name}-role"
  cluster_admin_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
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
      { Sid = "ReadOnlyFoundationAddonsBundle", Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion"], Resource = "arn:aws:s3:::${var.artifact_bucket_name}/${local.source_key}" },
      { Sid = "ListOnlyFoundationAddonsState", Effect = "Allow", Action = "s3:ListBucket", Resource = "arn:aws:s3:::${var.state_bucket_name}", Condition = { StringLike = { "s3:prefix" = [local.state_key, "${local.state_key}.tflock"] } } },
      { Sid = "ReadWriteOnlyFoundationAddonsState", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = "arn:aws:s3:::${var.state_bucket_name}/${local.state_key}" },
      { Sid = "LockOnlyFoundationAddonsState", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "arn:aws:s3:::${var.state_bucket_name}/${local.state_key}.tflock" },
      { Sid = "DescribeOnlyPrivateCluster", Effect = "Allow", Action = "eks:DescribeCluster", Resource = var.cluster_arn },
      { Sid = "DescribeSecurityGroupsForVpcBuild", Effect = "Allow", Action = "ec2:DescribeSecurityGroups", Resource = "*" },
      { Sid = "PullOnlyPinnedDeployerImage", Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], Resource = "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/${split("/", var.deployer_repository_url)[1]}" },
      { Sid = "AuthenticateOnlyToPullDeployerImage", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
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
# no AWS write permission beyond its own isolated Terraform state and lock.
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
