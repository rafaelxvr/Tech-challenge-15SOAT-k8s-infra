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
    db_staging           = { repository = "oficina-db-infra", environment = "staging", source_prefix = "releases/db/staging", terraform_state_key = "db/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/db_staging.tfvars.json" }
    db_production        = { repository = "oficina-db-infra", environment = "production", source_prefix = "releases/db/production", terraform_state_key = "db/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/db_production.tfvars.json" }
    functions_staging    = { repository = "oficina-functions", environment = "staging", source_prefix = "releases/functions/staging", terraform_state_key = "functions/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/functions_staging.tfvars.json" }
    functions_production = { repository = "oficina-functions", environment = "production", source_prefix = "releases/functions/production", terraform_state_key = "functions/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/functions_production.tfvars.json" }
    app_staging          = { repository = "oficina-app", environment = "staging", source_prefix = "releases/app/staging", terraform_state_key = "app/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/app_staging.tfvars.json" }
    app_production       = { repository = "oficina-app", environment = "production", source_prefix = "releases/app/production", terraform_state_key = "app/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/app_production.tfvars.json" }
  }
}

run "eight_bounded_private_deployers" {
  command = plan
  assert {
    condition     = length(aws_codebuild_project.deploy) == 8 && alltrue([for project in aws_codebuild_project.deploy : project.concurrent_build_limit == 1 && project.environment[0].compute_type == "BUILD_GENERAL1_SMALL" && project.environment[0].image_pull_credentials_type == "SERVICE_ROLE" && !project.environment[0].privileged_mode && project.source[0].type == "S3"])
    error_message = "The four repositories require exactly eight bounded, S3-sourced non-privileged deployers."
  }
  assert {
    condition = length([for key, deployment in var.deployments : key if deployment.repository == var.kubernetes_repository]) == 2 && alltrue([
      for key, deployment in var.deployments :
      deployment.repository == var.kubernetes_repository ?
      length(local.executor_eks_actions[key]) == 5 && contains(local.executor_eks_actions[key], "eks:UpdateNodegroupConfig") && contains(local.executor_eks_actions[key], "eks:UpdateNodegroupVersion") :
      length(local.executor_eks_actions[key]) == 1 && local.executor_eks_actions[key][0] == "eks:DescribeCluster"
    ])
    error_message = "Only the Kubernetes repository's staging and production roles may update reviewed node groups."
  }
  assert {
    condition     = aws_ecr_repository.deployer.image_tag_mutability == "IMMUTABLE" && can(regex("^sha256:", var.deployer_image_digest))
    error_message = "Every deployer must consume the platform ECR image by immutable digest."
  }
  assert {
    condition = alltrue([for key, project in aws_codebuild_project.deploy :
      project.source[0].buildspec == local.rendered_deployment_buildspecs[key] &&
      !contains([for variable in project.environment[0].environment_variable : variable.name], "DEPLOYMENT_TFVARS_PATH") &&
      !contains([for variable in project.environment[0].environment_variable : variable.name], "DEPLOYMENT_MODE") &&
      !contains([for variable in project.environment[0].environment_variable : variable.name], "TERRAFORM_BACKEND_BUCKET") &&
      !contains([for variable in project.environment[0].environment_variable : variable.name], "TERRAFORM_BACKEND_KEY") &&
      !contains([for variable in project.environment[0].environment_variable : variable.name], "TERRAFORM_BACKEND_LOCK_KEY") &&
      !contains([for variable in project.environment[0].environment_variable : variable.name], "TERRAFORM_BACKEND_REGION") &&
      strcontains(project.source[0].buildspec, "reviewed_environment=\"${var.deployments[key].environment}\"") &&
      strcontains(project.source[0].buildspec, "reviewed_backend_bucket=\"${var.state_bucket_name}\"") &&
      strcontains(project.source[0].buildspec, "reviewed_backend_key=\"${var.deployments[key].terraform_state_key}\"") &&
      strcontains(project.source[0].buildspec, "reviewed_backend_lock_key=\"${var.deployments[key].terraform_state_key}.tflock\"") &&
      strcontains(project.source[0].buildspec, "reviewed_backend_region=\"${var.aws_region}\"") &&
      strcontains(project.source[0].buildspec, "reviewed_deployment_mode=\"${var.deployments[key].deployment_mode}\"") &&
      strcontains(project.source[0].buildspec, "reviewed_tfvars_path=\"${var.deployments[key].terraform_variables_path}\"") &&
      strcontains(project.source[0].buildspec, "Deployment environment override does not match this reviewed executor.") &&
      !strcontains(project.source[0].buildspec, "$${TERRAFORM_BACKEND_KEY}")
    ])
    error_message = "Every executor must render its exact backend, deployment mode, and tfvars path into the Terraform-owned bootstrap, outside StartBuild overrides."
  }
  assert {
    condition = alltrue([
      for repository in distinct([for deployment in values(var.deployments) : deployment.repository]) :
      length([for deployment in values(var.deployments) : deployment.environment if deployment.repository == repository]) == 2 &&
      toset([for deployment in values(var.deployments) : deployment.environment if deployment.repository == repository]) == toset(["staging", "production"])
    ])
    error_message = "Every repository must receive exactly one executor for each reviewed environment."
  }
}

run "rejects_duplicate_environment_for_a_repository" {
  command = plan

  variables {
    deployments = {
      k8s_staging           = { repository = "oficina-k8s-infra", environment = "staging", source_prefix = "releases/k8s/staging", terraform_state_key = "environments/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/k8s_staging.tfvars.json" }
      k8s_production        = { repository = "oficina-k8s-infra", environment = "production", source_prefix = "releases/k8s/production", terraform_state_key = "environments/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/k8s_production.tfvars.json" }
      db_staging            = { repository = "oficina-db-infra", environment = "staging", source_prefix = "releases/db/staging", terraform_state_key = "db/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/db_staging.tfvars.json" }
      db_production         = { repository = "oficina-db-infra", environment = "production", source_prefix = "releases/db/production", terraform_state_key = "db/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/db_production.tfvars.json" }
      functions_staging     = { repository = "oficina-functions", environment = "staging", source_prefix = "releases/functions/staging", terraform_state_key = "functions/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/functions_staging.tfvars.json" }
      functions_production  = { repository = "oficina-functions", environment = "production", source_prefix = "releases/functions/production", terraform_state_key = "functions/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/functions_production.tfvars.json" }
      app_staging           = { repository = "oficina-app", environment = "staging", source_prefix = "releases/app/staging", terraform_state_key = "app/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/app_staging.tfvars.json" }
      app_staging_duplicate = { repository = "oficina-app", environment = "staging", source_prefix = "releases/app/staging-duplicate", terraform_state_key = "app/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/app_production.tfvars.json" }
    }
  }

  expect_failures = [var.deployments]
}
