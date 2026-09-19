mock_provider "aws" {}

variables {
  aws_region                     = "us-east-1"
  account_id                     = "123456789012"
  name                           = "oficina-phase3"
  artifact_bucket_name           = "oficina-phase3-artifacts-example"
  state_bucket_name              = "oficina-phase3-state-example"
  vpc_cidr                       = "10.42.0.0/16"
  availability_zones             = ["us-east-1a", "us-east-1b"]
  public_subnet_cidrs            = ["10.42.0.0/24", "10.42.1.0/24"]
  private_subnet_cidrs           = ["10.42.16.0/20", "10.42.32.0/20"]
  database_subnet_cidrs          = ["10.42.64.0/24", "10.42.65.0/24"]
  oidc_thumbprint                = "0123456789012345678901234567890123456789"
  node_ami_release_version       = "1.35.0-20260901"
  vpc_cni_addon_version          = "v1.21.0-eksbuild.1"
  coredns_addon_version          = "v1.12.0-eksbuild.1"
  deployer_image_digest          = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  kubernetes_repository          = "oficina-k8s-infra"
  platform_binding_principal_arn = "arn:aws:iam::123456789012:role/oficina-platform-binding"
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

run "foundation_output_schema_is_bounded" {
  command = plan
  assert {
    condition     = length(module.staging_app_irsa) == 0 && output.staging_app_irsa_role_arn == null && length(module.staging_migration_irsa) == 0 && output.staging_migration_identity_json == null
    error_message = "Existing foundation and production must create no APP role by default."
  }
  assert {
    condition = alltrue([for environment in ["staging", "production"] :
      var.deployments["db_${environment}"].source_prefix == "releases/database/${environment}" &&
      var.deployments["db_${environment}"].terraform_state_key == "database/${environment}.tfstate" &&
      var.deployments["db_${environment}"].terraform_variables_path == "/tmp/oficina/database_${environment}.tfvars.json"
    ])
    error_message = "Foundation DB fixtures must match the approved database deployment contract."
  }
  assert {
    condition     = output.schema_version == 1 && output.environment == "foundation" && length(output.private_subnet_ids) == 2 && length(output.database_subnet_ids) == 2
    error_message = "Foundation must export only the v1 network boundary with two private and two database subnets."
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.functions_to_aws_apis.from_port == 443 && aws_vpc_security_group_egress_rule.functions_to_database.to_port == 5432 && aws_vpc_security_group_ingress_rule.database_from_functions.from_port == 5432
    error_message = "Foundation must export one Lambda security group with PostgreSQL-only database access."
  }
  assert {
    condition     = length(output.codebuild_projects) == 8 && alltrue([for project in values(output.codebuild_projects) : contains(keys(project), "projectName") && contains(keys(project), "roleName") && contains(keys(project), "roleArn")])
    error_message = "Foundation must export the bounded eight-project deployer name and role map."
  }
  assert {
    condition     = aws_lb.internal.load_balancer_type == "application" && length(aws_lb_listener.backend) == 2 && aws_lb_listener.backend["staging"].port == 8080 && aws_lb_listener.backend["production"].port == 8081 && aws_lb_listener.backend["staging"].default_action[0].fixed_response[0].status_code == "503"
    error_message = "Foundation must own one private ALB, both safe default listeners, and the shared private VPC link."
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.vpc_link_to_alb) == 2 && aws_vpc_security_group_egress_rule.alb_to_cluster.to_port == 8080 && aws_vpc_security_group_ingress_rule.alb_to_cluster.from_port == 8080
    error_message = "ALB traffic must be owned by standalone VPC-link ingress and registered-pod egress rules only."
  }
  assert {
    condition     = output.foundation_addons_executor.stateKey == "foundation-addons/terraform.tfstate"
    error_message = "Foundation must expose the dedicated private executor with its isolated addon state key."
  }
  assert {
    condition     = aws_iam_role.load_balancer_controller.name == "oficina-phase3-aws-load-balancer-controller" && can(regex("RegisterTargets", aws_iam_role_policy.load_balancer_controller.policy)) && can(regex("ModifyTargetGroupAttributes", aws_iam_role_policy.load_balancer_controller.policy)) && aws_eks_access_entry.platform_binding.principal_arn == var.platform_binding_principal_arn && length(keys(output.backend_listener_arns)) == 2
    error_message = "The controller needs required target maintenance actions and a separate platform-binding principal."
  }
}

run "explicit_staging_runtime_role" {
  command = plan
  override_module {
    target = module.cluster
    outputs = {
      cluster_name                       = "oficina-phase3"
      cluster_arn                        = "arn:aws:eks:us-east-1:123456789012:cluster/oficina-phase3"
      cluster_security_group_id          = "sg-0123456789abcdef0"
      cluster_endpoint                   = "https://example.eks.amazonaws.com"
      cluster_certificate_authority_data = "ZXhhbXBsZQ=="
      node_group_names                   = { "us-east-1a" = "workers-a", "us-east-1b" = "workers-b" }
      node_group_arns                    = ["arn:aws:eks:us-east-1:123456789012:nodegroup/oficina-phase3/workers-a/example", "arn:aws:eks:us-east-1:123456789012:nodegroup/oficina-phase3/workers-b/example"]
      cluster_oidc_issuer                = "https://oidc.eks.us-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF"
      cluster_oidc_provider_arn          = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF"
    }
  }
  variables {
    staging_app_irsa = {
      runtime_secret_arns = {
        app              = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/app-AbCd12"
        authorizer_trust = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/authorizer-trust-EfGh34"
        newrelic_ingest  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-IjKl56"
      }
      notification_queue_arn = "arn:aws:sqs:us-east-1:123456789012:oficina-phase3-staging-notifications.fifo"
    }
  }
  assert {
    condition     = keys(module.staging_app_irsa) == ["staging"] && module.staging_app_irsa["staging"].role_name == "oficina-phase3-staging-app"
    error_message = "An explicit input may create exactly the staging role through foundation ownership."
  }
}
