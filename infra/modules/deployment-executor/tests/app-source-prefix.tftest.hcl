mock_provider "aws" {}

variables {
  name                  = "oficina-phase3"
  aws_region            = "us-east-1"
  account_id            = "123456789012"
  vpc_id                = "vpc-12345678"
  cluster_arn           = "arn:aws:eks:us-east-1:123456789012:cluster/oficina-phase3"
  node_group_arns       = ["arn:aws:eks:us-east-1:123456789012:nodegroup/oficina-phase3/workers-a/example", "arn:aws:eks:us-east-1:123456789012:nodegroup/oficina-phase3/workers-b/example"]
  kubernetes_repository = "oficina-k8s-infra"
  artifact_bucket_name  = "oficina-phase3-artifacts-example"
  state_bucket_name     = "oficina-phase3-state-example"
  private_subnet_ids    = ["subnet-a", "subnet-b"]
  security_group_ids    = ["sg-codebuild"]
  deployer_image_digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  deployments = {
    k8s_staging          = { repository = "oficina-k8s-infra", environment = "staging", source_prefix = "releases/k8s/staging", terraform_state_key = "environments/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/k8s_staging.tfvars.json" }
    k8s_production       = { repository = "oficina-k8s-infra", environment = "production", source_prefix = "releases/k8s/production", terraform_state_key = "environments/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/k8s_production.tfvars.json" }
    db_staging           = { repository = "oficina-db-infra", environment = "staging", source_prefix = "releases/database/staging", terraform_state_key = "database/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/database_staging.tfvars.json" }
    db_production        = { repository = "oficina-db-infra", environment = "production", source_prefix = "releases/database/production", terraform_state_key = "database/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/database_production.tfvars.json" }
    functions_staging    = { repository = "oficina-functions", environment = "staging", source_prefix = "releases/functions/staging", terraform_state_key = "functions/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/functions_staging.tfvars.json" }
    functions_production = { repository = "oficina-functions", environment = "production", source_prefix = "releases/functions/production", terraform_state_key = "functions/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/functions_production.tfvars.json" }
    app_staging          = { repository = "oficina-app", environment = "staging", source_prefix = "releases/app/staging", terraform_state_key = "app/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/app_staging.tfvars.json" }
    app_production       = { repository = "oficina-app", environment = "production", source_prefix = "releases/app/production", terraform_state_key = "app/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/app_production.tfvars.json" }
  }
}

override_resource {
  target          = aws_ecr_repository.deployer
  override_during = plan
  values = {
    arn = "arn:aws:ecr:us-east-1:123456789012:repository/oficina-phase3-deployer"
  }
}
run "app_source_and_policy_share_canonical_prefix" {
  command = plan
  assert {
    condition = alltrue([for environment in ["staging", "production"] :
      aws_codebuild_project.deploy["app_${environment}"].source[0].location == "${var.artifact_bucket_name}/releases/app/${environment}/bundle.zip" &&
      one([for statement in jsondecode(local.codebuild_policies["app_${environment}"]).Statement : statement.Resource if statement.Sid == "ReadOnlyReviewedSourcePrefix"]) == "arn:aws:s3:::${var.artifact_bucket_name}/releases/app/${environment}/*" &&
      strcontains(local.rendered_deployment_buildspecs["app_${environment}"], "reviewed_deployment_mode=\"plan\"")
    ])
    error_message = "APP source location and IAM must use the same environment prefix without enabling apply."
  }
}

run "reject_legacy_app_staging_prefix" {
  command = plan
  variables {
    deployments = merge(var.deployments, {
      app_staging = merge(var.deployments.app_staging, { source_prefix = "releases/application/staging" })
    })
  }
  expect_failures = [var.deployments]
}

run "reject_cross_environment_app_staging_prefix" {
  command = plan
  variables {
    deployments = merge(var.deployments, {
      app_staging = merge(var.deployments.app_staging, { source_prefix = "releases/app/production" })
    })
  }
  expect_failures = [var.deployments]
}

run "production_input_is_not_rewritten" {
  command = plan
  variables {
    deployments = merge(var.deployments, {
      app_production = merge(var.deployments.app_production, { source_prefix = "releases/application/production" })
    })
  }
  assert {
    condition = (aws_codebuild_project.deploy["app_production"].source[0].location == "${var.artifact_bucket_name}/releases/application/production/bundle.zip" &&
    one([for statement in jsondecode(local.codebuild_policies["app_production"]).Statement : statement.Resource if statement.Sid == "ReadOnlyReviewedSourcePrefix"]) == "arn:aws:s3:::${var.artifact_bucket_name}/releases/application/production/*")
    error_message = "The staging-only guard must preserve the separately reviewed production input and IAM scope."
  }
}
