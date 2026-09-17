provider "aws" { region = var.aws_region }

module "platform" {
  source                 = "../../modules/platform-environment"
  name                   = var.name
  environment            = "production"
  namespace              = "oficina-production"
  aws_region             = var.aws_region
  account_id             = var.account_id
  vpc_id                 = var.foundation_outputs.vpc_id
  cluster_name           = var.foundation_outputs.cluster_name
  backend_listener_arn   = var.foundation_outputs.backend_listener_arns["production"]
  vpc_link_id            = var.foundation_outputs.vpc_link_id
  listener_port          = 8081
  deployer_principal_arn = var.foundation_outputs.codebuild_projects["k8s_production"].roleArn
  authorizer_handoff     = var.authorizer_handoff
  cors_allow_origins     = var.gateway_allowed_origins
}
