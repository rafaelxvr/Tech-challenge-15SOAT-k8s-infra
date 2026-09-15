mock_provider "aws" {}

variables {
  name                  = "oficina-phase3"
  aws_region            = "us-east-1"
  account_id            = "123456789012"
  vpc_id                = "vpc-12345678"
  cluster_arn           = "arn:aws:eks:us-east-1:123456789012:cluster/oficina-phase3"
  node_group_arns       = ["arn:aws:eks:us-east-1:123456789012:nodegroup/oficina-phase3/workers-a/example", "arn:aws:eks:us-east-1:123456789012:nodegroup/oficina-phase3/workers-b/example"]
  artifact_bucket_name  = "oficina-phase3-artifacts-example"
  private_subnet_ids    = ["subnet-a", "subnet-b"]
  security_group_ids    = ["sg-codebuild"]
  deployer_image_digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  deployments = {
    k8s_staging          = { repository = "oficina-k8s-infra", environment = "staging", source_prefix = "releases/k8s/staging" }
    k8s_production       = { repository = "oficina-k8s-infra", environment = "production", source_prefix = "releases/k8s/production" }
    db_staging           = { repository = "oficina-db-infra", environment = "staging", source_prefix = "releases/db/staging" }
    db_production        = { repository = "oficina-db-infra", environment = "production", source_prefix = "releases/db/production" }
    functions_staging    = { repository = "oficina-functions", environment = "staging", source_prefix = "releases/functions/staging" }
    functions_production = { repository = "oficina-functions", environment = "production", source_prefix = "releases/functions/production" }
    app_staging          = { repository = "oficina-app", environment = "staging", source_prefix = "releases/app/staging" }
    app_production       = { repository = "oficina-app", environment = "production", source_prefix = "releases/app/production" }
  }
}

run "eight_bounded_private_deployers" {
  command = plan
  assert {
    condition     = length(aws_codebuild_project.deploy) == 8 && alltrue([for project in aws_codebuild_project.deploy : project.concurrent_build_limit == 1 && project.environment[0].compute_type == "BUILD_GENERAL1_SMALL" && project.environment[0].image_pull_credentials_type == "SERVICE_ROLE" && !project.environment[0].privileged_mode && project.source[0].type == "S3"])
    error_message = "The four repositories require exactly eight bounded, S3-sourced non-privileged deployers."
  }
  assert {
    condition     = aws_ecr_repository.deployer.image_tag_mutability == "IMMUTABLE" && can(regex("^sha256:", var.deployer_image_digest))
    error_message = "Every deployer must consume the platform ECR image by immutable digest."
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
      k8s_staging          = { repository = "oficina-k8s-infra", environment = "staging", source_prefix = "releases/k8s/staging" }
      k8s_production       = { repository = "oficina-k8s-infra", environment = "production", source_prefix = "releases/k8s/production" }
      db_staging           = { repository = "oficina-db-infra", environment = "staging", source_prefix = "releases/db/staging" }
      db_production        = { repository = "oficina-db-infra", environment = "production", source_prefix = "releases/db/production" }
      functions_staging    = { repository = "oficina-functions", environment = "staging", source_prefix = "releases/functions/staging" }
      functions_production = { repository = "oficina-functions", environment = "production", source_prefix = "releases/functions/production" }
      app_staging          = { repository = "oficina-app", environment = "staging", source_prefix = "releases/app/staging" }
      app_production       = { repository = "oficina-app", environment = "staging", source_prefix = "releases/app/production" }
    }
  }

  expect_failures = [var.deployments]
}
