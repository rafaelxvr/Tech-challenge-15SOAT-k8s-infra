mock_provider "aws" {}

variables {
  aws_region               = "us-east-1"
  account_id               = "123456789012"
  name                     = "oficina-phase3"
  artifact_bucket_name     = "oficina-phase3-artifacts-example"
  vpc_cidr                 = "10.42.0.0/16"
  availability_zones       = ["us-east-1a", "us-east-1b"]
  public_subnet_cidrs      = ["10.42.0.0/24", "10.42.1.0/24"]
  private_subnet_cidrs     = ["10.42.16.0/20", "10.42.32.0/20"]
  database_subnet_cidrs    = ["10.42.64.0/24", "10.42.65.0/24"]
  oidc_thumbprint          = "0123456789012345678901234567890123456789"
  node_ami_release_version = "1.35.0-20260901"
  vpc_cni_addon_version    = "v1.21.0-eksbuild.1"
  coredns_addon_version    = "v1.12.0-eksbuild.1"
  deployer_image_digest    = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  kubernetes_repository    = "oficina-k8s-infra"
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

run "foundation_output_schema_is_bounded" {
  command = plan
  assert {
    condition     = output.schema_version == 1 && output.environment == "foundation" && length(output.private_subnet_ids) == 2 && length(output.database_subnet_ids) == 2
    error_message = "Foundation must export only the v1 network boundary with two private and two database subnets."
  }
  assert {
    condition     = length(output.codebuild_projects) == 8 && alltrue([for project in values(output.codebuild_projects) : contains(keys(project), "projectName") && contains(keys(project), "roleName") && contains(keys(project), "roleArn")])
    error_message = "Foundation must export the bounded eight-project deployer name and role map."
  }
}
