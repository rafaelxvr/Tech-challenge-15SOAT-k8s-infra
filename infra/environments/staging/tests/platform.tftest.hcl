mock_provider "aws" {}

run "staging_binds_only_staging_platform_contract" {
  command = plan

  variables {
    aws_region                     = "us-east-1"
    name                           = "oficina"
    vpc_id                         = "vpc-12345678"
    cluster_name                   = "oficina"
    cluster_security_group_id      = "sg-cluster"
    internal_alb_arn               = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/oficina/1234567890abcdef"
    internal_alb_security_group_id = "sg-alb"
    vpc_link_id                    = "abc123"
    vpc_link_security_group_id     = "sg-vpclink"
    deployer_principal_arn         = "arn:aws:iam::123456789012:role/oficina-k8s-staging-deploy"
  }

  assert {
    condition     = output.namespace == "oficina-staging" && output.listener_port == 8080
    error_message = "Staging must not bind the production namespace or listener port."
  }
}
