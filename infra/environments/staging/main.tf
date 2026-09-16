provider "aws" { region = var.aws_region }

module "platform" {
  source                         = "../../modules/platform-environment"
  name                           = var.name
  environment                    = "staging"
  namespace                      = "oficina-staging"
  aws_region                     = var.aws_region
  vpc_id                         = var.vpc_id
  cluster_name                   = var.cluster_name
  cluster_security_group_id      = var.cluster_security_group_id
  internal_alb_arn               = var.internal_alb_arn
  internal_alb_security_group_id = var.internal_alb_security_group_id
  vpc_link_id                    = var.vpc_link_id
  vpc_link_security_group_id     = var.vpc_link_security_group_id
  listener_port                  = 8080
  deployer_principal_arn         = var.deployer_principal_arn
}
