mock_provider "aws" {}

variables {
  name                   = "oficina-phase3"
  environment            = "staging"
  aws_region             = "us-east-1"
  account_id             = "123456789012"
  vpc_id                 = "vpc-12345678"
  cluster_name           = "oficina-phase3"
  backend_listener_arn   = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/oficina/1234567890abcdef/abcdef1234567890"
  vpc_link_id            = "abc123"
  listener_port          = 8080
  namespace              = "oficina-staging"
  deployer_principal_arn = "arn:aws:iam::123456789012:role/oficina-k8s-staging-deploy"
  cors_allow_origins     = ["https://staging.example.invalid"]
}

run "default_does_not_add_app_identity" {
  command = plan
  assert {
    condition     = length(aws_eks_access_entry.app_deployer) == 0
    error_message = "Optional APP identity must default absent."
  }
}

run "exact_staging_identity_matches_rolebinding" {
  command = plan
  variables {
    app_deployer_principal_arn = "arn:aws:iam::123456789012:role/oficina-phase3-oficina-app-staging-deploy-role"
  }
  assert {
    condition = (
      length(aws_eks_access_entry.app_deployer) == 1 &&
      aws_eks_access_entry.app_deployer[0].principal_arn == var.app_deployer_principal_arn &&
      aws_eks_access_entry.app_deployer[0].user_name == var.app_deployer_principal_arn &&
      aws_eks_access_entry.app_deployer[0].type == "STANDARD" &&
      aws_eks_access_entry.app_deployer[0].cluster_name == var.cluster_name &&
      length(aws_eks_access_entry.app_deployer[0].kubernetes_groups) == 0 &&
      aws_eks_access_entry.deployer.principal_arn == var.deployer_principal_arn
    )
    error_message = "APP authentication must match the exact RoleBinding User, without groups or replacing the existing executor."
  }
}

run "production_default_is_unchanged" {
  command = plan
  variables {
    environment   = "production"
    namespace     = "oficina-production"
    listener_port = 8081
  }
  assert {
    condition     = length(aws_eks_access_entry.app_deployer) == 0
    error_message = "Production cannot gain an APP identity by default."
  }
}

run "production_explicit_identity_rejected" {
  command = plan
  variables {
    environment                = "production"
    namespace                  = "oficina-production"
    listener_port              = 8081
    app_deployer_principal_arn = "arn:aws:iam::123456789012:role/oficina-phase3-oficina-app-staging-deploy-role"
  }
  expect_failures = [var.app_deployer_principal_arn]
}

run "cross_account_role_rejected" {
  command = plan
  variables {
    app_deployer_principal_arn = "arn:aws:iam::999999999999:role/oficina-phase3-oficina-app-staging-deploy-role"
  }
  expect_failures = [var.app_deployer_principal_arn]
}

run "production_role_rejected" {
  command = plan
  variables {
    app_deployer_principal_arn = "arn:aws:iam::123456789012:role/oficina-phase3-oficina-app-production-deploy-role"
  }
  expect_failures = [var.app_deployer_principal_arn]
}

run "k8s_executor_role_rejected" {
  command = plan
  variables {
    app_deployer_principal_arn = "arn:aws:iam::123456789012:role/oficina-phase3-oficina-k8s-infra-staging-deploy-role"
  }
  expect_failures = [var.app_deployer_principal_arn]
}
