locals {
  deployer_repository_name = "${var.name}-deployer"
  project_names = {
    for key, deployment in var.deployments : key => "${var.name}-${replace(deployment.repository, "/", "-")}-${deployment.environment}-deploy"
  }
  codebuild_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CodeBuildOnly"
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })
  codebuild_policies = {
    for key, deployment in var.deployments : key => jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "ReadOnlyReviewedSourcePrefix"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:GetObjectVersion"]
          Resource = "arn:aws:s3:::${var.artifact_bucket_name}/${deployment.source_prefix}/*"
        },
        {
          Sid      = "WriteOnlyThisBuildLogGroup"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/codebuild/${local.project_names[key]}:log-stream:*"
        },
        {
          Sid      = "PullOnlyPlatformDeployerImage"
          Effect   = "Allow"
          Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
          Resource = aws_ecr_repository.deployer.arn
        },
        # AWS requires Resource=* for this account-scoped token action. Layer
        # and image retrieval stay restricted to the platform repository above.
        {
          Sid      = "AuthenticateOnlyToPullPlatformImage"
          Effect   = "Allow"
          Action   = "ecr:GetAuthorizationToken"
          Resource = "*"
        },
        {
          Sid      = "ControlOnlyReviewedClusterAndNodeGroups"
          Effect   = "Allow"
          Action   = ["eks:DescribeCluster", "eks:DescribeNodegroup", "eks:DescribeUpdate", "eks:UpdateNodegroupConfig", "eks:UpdateNodegroupVersion"]
          Resource = concat([var.cluster_arn], var.node_group_arns)
        }
      ]
    })
  }
}

resource "aws_ecr_repository" "deployer" {
  name                 = local.deployer_repository_name
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}

resource "aws_ecr_lifecycle_policy" "deployer" {
  repository = aws_ecr_repository.deployer.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Retain one reviewed deployer image within the approved retained-image allowance."
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 1 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_iam_role" "codebuild" {
  for_each           = var.deployments
  name               = "${local.project_names[each.key]}-role"
  assume_role_policy = local.codebuild_assume_role_policy
}

resource "aws_iam_role_policy" "codebuild" {
  for_each = var.deployments
  name     = "bounded-deployment-executor"
  role     = aws_iam_role.codebuild[each.key].id
  policy   = local.codebuild_policies[each.key]
}

resource "aws_codebuild_project" "deploy" {
  for_each               = var.deployments
  name                   = local.project_names[each.key]
  description            = "Short-lived private deployment executor for ${each.value.repository}/${each.value.environment}."
  service_role           = aws_iam_role.codebuild[each.key].arn
  build_timeout          = 30
  queued_timeout         = 30
  concurrent_build_limit = 1

  artifacts { type = "NO_ARTIFACTS" }
  source {
    type      = "S3"
    location  = "${var.artifact_bucket_name}/${each.value.source_prefix}/bundle.zip"
    buildspec = "buildspec.deploy.yml"
  }
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "${aws_ecr_repository.deployer.repository_url}@${var.deployer_image_digest}"
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
      group_name  = "/aws/codebuild/${local.project_names[each.key]}"
      stream_name = "deploy"
    }
  }
}
