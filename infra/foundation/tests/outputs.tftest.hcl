mock_provider "aws" {}
mock_provider "helm" {}

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
    db_staging           = { repository = "oficina-db-infra", environment = "staging", source_prefix = "releases/db/staging", terraform_state_key = "db/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/db_staging.tfvars.json" }
    db_production        = { repository = "oficina-db-infra", environment = "production", source_prefix = "releases/db/production", terraform_state_key = "db/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/db_production.tfvars.json" }
    functions_staging    = { repository = "oficina-functions", environment = "staging", source_prefix = "releases/functions/staging", terraform_state_key = "functions/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/functions_staging.tfvars.json" }
    functions_production = { repository = "oficina-functions", environment = "production", source_prefix = "releases/functions/production", terraform_state_key = "functions/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/functions_production.tfvars.json" }
    app_staging          = { repository = "oficina-app", environment = "staging", source_prefix = "releases/app/staging", terraform_state_key = "app/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/app_staging.tfvars.json" }
    app_production       = { repository = "oficina-app", environment = "production", source_prefix = "releases/app/production", terraform_state_key = "app/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/app_production.tfvars.json" }
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
  assert {
    condition     = aws_lb.internal.load_balancer_type == "application" && length(aws_lb_listener.backend) == 2 && aws_lb_listener.backend["staging"].port == 8080 && aws_lb_listener.backend["production"].port == 8081 && aws_lb_listener.backend["staging"].default_action[0].fixed_response[0].status_code == "503"
    error_message = "Foundation must own one private ALB, both safe default listeners, and the shared private VPC link."
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.vpc_link_to_alb) == 2 && aws_vpc_security_group_ingress_rule.alb_to_cluster.from_port == 8080 && length(aws_security_group.internal_alb.ingress) == 0 && length(aws_security_group.internal_alb.egress) == 0
    error_message = "ALB traffic must be closed by default and allow only VPC-link listeners plus port 8080 to registered pods."
  }
  assert {
    condition     = helm_release.aws_load_balancer_controller.version == "1.12.0" && helm_release.metrics_server.version == "3.12.2" && helm_release.secrets_store_csi_driver.version == "1.4.8" && helm_release.secrets_store_csi_aws_provider.version == "0.3.9"
    error_message = "Every required controller must be installed from an exact reviewed chart version."
  }
  assert {
    condition     = aws_iam_role.load_balancer_controller.name == "oficina-phase3-aws-load-balancer-controller" && can(regex("RegisterTargets", aws_iam_role_policy.load_balancer_controller.policy)) && can(regex("ModifyTargetGroupAttributes", aws_iam_role_policy.load_balancer_controller.policy)) && aws_eks_access_entry.platform_binding.principal_arn == var.platform_binding_principal_arn && length(keys(output.backend_listener_arns)) == 2
    error_message = "The controller needs required target maintenance actions and a separate platform-binding principal."
  }
}
