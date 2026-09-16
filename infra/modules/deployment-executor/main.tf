locals {
  deployer_repository_name = "${var.name}-deployer"
  project_names = {
    for key, deployment in var.deployments : key => "${var.name}-${replace(deployment.repository, "/", "-")}-${deployment.environment}-deploy"
  }
  eks_describe_actions = ["eks:DescribeCluster"]
  eks_node_group_update_actions = [
    "eks:DescribeNodegroup",
    "eks:DescribeUpdate",
    "eks:UpdateNodegroupConfig",
    "eks:UpdateNodegroupVersion"
  ]
  executor_eks_actions = {
    for key, deployment in var.deployments : key => deployment.repository == var.kubernetes_repository ? concat(local.eks_describe_actions, local.eks_node_group_update_actions) : local.eks_describe_actions
  }
  executor_eks_resources = {
    for key, deployment in var.deployments : key => deployment.repository == var.kubernetes_repository ? concat([var.cluster_arn], var.node_group_arns) : [var.cluster_arn]
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
          Sid      = deployment.repository == var.kubernetes_repository ? "ControlOnlyReviewedClusterAndNodeGroups" : "DescribeOnlyReviewedCluster"
          Effect   = "Allow"
          Action   = local.executor_eks_actions[key]
          Resource = local.executor_eks_resources[key]
        }
      ]
    })
  }
  # The executor's buildspec is Terraform-owned. Nothing from the archive is
  # executed until this bootstrap has re-downloaded the exact object version
  # and verified both the source and release-manifest digests.
  inline_deployment_buildspec = <<-YAML
    version: 0.2
    phases:
      build:
        commands:
          - |
            set -euo pipefail
            required=(DEPLOY_ENVIRONMENT SOURCE_BUCKET SOURCE_KEY SOURCE_VERSION_ID EXPECTED_SHA256 RELEASE_MANIFEST_KEY RELEASE_MANIFEST_VERSION_ID EXPECTED_MANIFEST_SHA256 SOURCE_COMMIT DEPLOYER_IMAGE_DIGEST DEPLOYMENT_TFVARS_PATH DEPLOYMENT_MODE)
            for variable in "$${required[@]}"; do
              if [ -z "$${!variable:-}" ]; then
                echo "Required deployment input is missing: $${variable}"
                exit 1
              fi
            done
            if [ "$${DEPLOYMENT_MODE}" != "plan" ] && [ "$${DEPLOYMENT_MODE}" != "apply" ]; then
              echo 'DEPLOYMENT_MODE must be plan or apply.'
              exit 1
            fi
            workdir="$(mktemp -d)"
            trap 'rm -rf "$${workdir}"' EXIT
            aws s3api get-object --bucket "$${SOURCE_BUCKET}" --key "$${SOURCE_KEY}" --version-id "$${SOURCE_VERSION_ID}" "$${workdir}/bundle.zip" >/dev/null
            actual_sha="$(sha256sum "$${workdir}/bundle.zip" | awk '{print $1}')"
            if [ "$${actual_sha}" != "$${EXPECTED_SHA256}" ]; then
              echo 'Source digest mismatch.'
              exit 1
            fi
            aws s3api get-object --bucket "$${SOURCE_BUCKET}" --key "$${RELEASE_MANIFEST_KEY}" --version-id "$${RELEASE_MANIFEST_VERSION_ID}" "$${workdir}/release-manifest.json" >/dev/null
            actual_manifest_sha="$(sha256sum "$${workdir}/release-manifest.json" | awk '{print $1}')"
            if [ "$${actual_manifest_sha}" != "$${EXPECTED_MANIFEST_SHA256}" ]; then
              echo 'Release manifest digest mismatch.'
              exit 1
            fi
            unzip -q "$${workdir}/bundle.zip" -d "$${workdir}/release"
            apply_switch=()
            if [ "$${DEPLOYMENT_MODE}" = "apply" ]; then apply_switch=(-ApplyReviewedPlan); fi
            pwsh -NoLogo -NoProfile -File "$${workdir}/release/scripts/deploy.ps1" -Environment "$${DEPLOY_ENVIRONMENT}" -ReleaseManifest "$${workdir}/release-manifest.json" -ExpectedSourceSha256 "$${EXPECTED_SHA256}" -ExpectedManifestSha256 "$${EXPECTED_MANIFEST_SHA256}" -SourceCommit "$${SOURCE_COMMIT}" -ExpectedDeployerImageDigest "$${DEPLOYER_IMAGE_DIGEST}" -TerraformVariablesFile "$${DEPLOYMENT_TFVARS_PATH}" "$${apply_switch[@]}"
  YAML
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
    buildspec = local.inline_deployment_buildspec
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
