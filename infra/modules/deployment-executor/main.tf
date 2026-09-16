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
      Statement = concat([
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
        },
        {
          Sid       = "ListOnlyItsTerraformStatePrefix"
          Effect    = "Allow"
          Action    = "s3:ListBucket"
          Resource  = "arn:aws:s3:::${var.state_bucket_name}"
          Condition = { StringLike = { "s3:prefix" = [deployment.terraform_state_key, "${deployment.terraform_state_key}.tflock"] } }
        },
        {
          Sid      = "ReadWriteOnlyItsTerraformState"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject"]
          Resource = "arn:aws:s3:::${var.state_bucket_name}/${deployment.terraform_state_key}"
        },
        {
          Sid      = "LockOnlyItsTerraformLockfile"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = "arn:aws:s3:::${var.state_bucket_name}/${deployment.terraform_state_key}.tflock"
        }
        ], [for statement in [
          {
            Sid      = "RunOnlyReviewedKubernetesPlatformProviderActions"
            Effect   = "Allow"
            Action   = ["sts:GetCallerIdentity", "apigateway:GET", "apigateway:POST", "apigateway:PATCH", "apigateway:DELETE", "elasticloadbalancing:DescribeListeners", "elasticloadbalancing:DescribeRules", "elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTags"]
            Resource = "*"
          },
          {
            Sid      = "ManageOnlyItsClusterAccessEntry"
            Effect   = "Allow"
            Action   = ["eks:CreateAccessEntry", "eks:DeleteAccessEntry", "eks:DescribeAccessEntry", "eks:ListAccessEntries", "eks:AssociateAccessPolicy", "eks:DisassociateAccessPolicy", "eks:ListAssociatedAccessPolicies"]
            Resource = var.cluster_arn
          },
          {
            Sid      = "CreateOnlyTaggedEnvironmentTargetGroups"
            Effect   = "Allow"
            Action   = "elasticloadbalancing:CreateTargetGroup"
            Resource = "*"
            Condition = { StringEquals = {
              "aws:RequestTag/project"     = "oficina-phase3"
              "aws:RequestTag/environment" = deployment.environment
            } }
          },
          {
            Sid    = "ManageOnlyNamedEnvironmentTargetAndListenerRules"
            Effect = "Allow"
            Action = ["elasticloadbalancing:DeleteTargetGroup", "elasticloadbalancing:ModifyTargetGroup", "elasticloadbalancing:ModifyTargetGroupAttributes", "elasticloadbalancing:CreateRule", "elasticloadbalancing:ModifyRule", "elasticloadbalancing:DeleteRule"]
            Resource = [
              "arn:aws:elasticloadbalancing:${var.aws_region}:${var.account_id}:targetgroup/${var.name}-${deployment.environment}-*/*",
              "arn:aws:elasticloadbalancing:${var.aws_region}:${var.account_id}:listener/app/${var.name}-internal/*/*",
              "arn:aws:elasticloadbalancing:${var.aws_region}:${var.account_id}:listener-rule/app/${var.name}-internal/*/*/*"
            ]
          }
      ] : statement if deployment.repository == var.kubernetes_repository])
    })
  }
  # The executor's buildspec is Terraform-owned. Nothing from the archive is
  # executed until this bootstrap has re-downloaded the exact object version
  # and verified both the source and release-manifest digests.
  inline_deployment_buildspec_template = <<-YAML
    version: 0.2
    phases:
      build:
        commands:
          - |
            set -euo pipefail
            reviewed_environment="__DEPLOYMENT_ENVIRONMENT__"
            reviewed_backend_bucket="__TERRAFORM_BACKEND_BUCKET__"
            reviewed_backend_key="__TERRAFORM_BACKEND_KEY__"
            reviewed_backend_lock_key="__TERRAFORM_BACKEND_LOCK_KEY__"
            reviewed_backend_region="__TERRAFORM_BACKEND_REGION__"
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
            if [ "$${DEPLOY_ENVIRONMENT}" != "$${reviewed_environment}" ]; then
              echo 'Deployment environment override does not match this reviewed executor.'
              exit 1
            fi
            if [ "$${reviewed_backend_lock_key}" != "$${reviewed_backend_key}.tflock" ]; then
              echo 'Terraform backend lock key is not derived from the reviewed state key.'
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
            for variable in TFVARS_OBJECT_KEY TFVARS_VERSION_ID EXPECTED_TFVARS_SHA256; do
              if [ -z "$${!variable:-}" ]; then echo "Required Terraform variables input is missing: $${variable}"; exit 1; fi
            done
            aws s3api get-object --bucket "$${SOURCE_BUCKET}" --key "$${TFVARS_OBJECT_KEY}" --version-id "$${TFVARS_VERSION_ID}" "$${DEPLOYMENT_TFVARS_PATH}" >/dev/null
            actual_tfvars_sha="$(sha256sum "$${DEPLOYMENT_TFVARS_PATH}" | awk '{print $1}')"
            if [ "$${actual_tfvars_sha}" != "$${EXPECTED_TFVARS_SHA256}" ]; then
              echo 'Terraform variables digest mismatch.'
              exit 1
            fi
            unzip -q "$${workdir}/bundle.zip" -d "$${workdir}/release"
            apply_switch=()
            if [ "$${DEPLOYMENT_MODE}" = "apply" ]; then apply_switch=(-ApplyReviewedPlan); fi
            pwsh -NoLogo -NoProfile -File "$${workdir}/release/scripts/deploy.ps1" -Environment "$${reviewed_environment}" -ReleaseManifest "$${workdir}/release-manifest.json" -ExpectedSourceSha256 "$${EXPECTED_SHA256}" -ExpectedManifestSha256 "$${EXPECTED_MANIFEST_SHA256}" -SourceCommit "$${SOURCE_COMMIT}" -ExpectedDeployerImageDigest "$${DEPLOYER_IMAGE_DIGEST}" -TerraformVariablesFile "$${DEPLOYMENT_TFVARS_PATH}" -TerraformBackendBucket "$${reviewed_backend_bucket}" -TerraformBackendKey "$${reviewed_backend_key}" -TerraformBackendLockKey "$${reviewed_backend_lock_key}" -TerraformBackendRegion "$${reviewed_backend_region}" "$${apply_switch[@]}"
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
    type     = "S3"
    location = "${var.artifact_bucket_name}/${each.value.source_prefix}/bundle.zip"
    # State selection is rendered into this Terraform-owned buildspec. A
    # StartBuild environmentVariablesOverride cannot alter these literals.
    buildspec = replace(replace(replace(replace(replace(
      local.inline_deployment_buildspec_template,
      "__DEPLOYMENT_ENVIRONMENT__", each.value.environment),
      "__TERRAFORM_BACKEND_BUCKET__", var.state_bucket_name),
      "__TERRAFORM_BACKEND_KEY__", each.value.terraform_state_key),
      "__TERRAFORM_BACKEND_LOCK_KEY__", "${each.value.terraform_state_key}.tflock"),
    "__TERRAFORM_BACKEND_REGION__", var.aws_region)
  }
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "${aws_ecr_repository.deployer.repository_url}@${var.deployer_image_digest}"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "SERVICE_ROLE"
    privileged_mode             = false
    environment_variable {
      name  = "DEPLOYMENT_MODE"
      value = each.value.deployment_mode
      type  = "PLAINTEXT"
    }
    environment_variable {
      name  = "DEPLOYMENT_TFVARS_PATH"
      value = each.value.terraform_variables_path
      type  = "PLAINTEXT"
    }
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
