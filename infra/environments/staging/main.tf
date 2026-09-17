provider "aws" { region = var.aws_region }

module "platform" {
  source                 = "../../modules/platform-environment"
  name                   = var.name
  environment            = "staging"
  namespace              = "oficina-staging"
  aws_region             = var.aws_region
  vpc_id                 = var.foundation_outputs.vpc_id
  cluster_name           = var.foundation_outputs.cluster_name
  backend_listener_arn   = var.foundation_outputs.backend_listener_arns["staging"]
  vpc_link_id            = var.foundation_outputs.vpc_link_id
  listener_port          = 8080
  deployer_principal_arn = var.foundation_outputs.codebuild_projects["k8s_staging"].roleArn
  authorizer_id          = var.authorizer_id
  cors_allow_origins     = var.gateway_allowed_origins
}
