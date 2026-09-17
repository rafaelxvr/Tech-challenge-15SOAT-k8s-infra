mock_provider "aws" {}

run "staging_binds_only_staging_platform_contract" {
  command = plan

  variables {
    aws_region = "us-east-1"
    account_id = "123456789012"
    name       = "oficina-phase3"
    foundation_outputs = {
      vpc_id                = "vpc-12345678"
      cluster_name          = "oficina"
      vpc_link_id           = "abc123"
      backend_listener_arns = { staging = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/oficina/1234567890abcdef/abcdef1234567890" }
      codebuild_projects    = { k8s_staging = { roleArn = "arn:aws:iam::123456789012:role/oficina-k8s-staging-deploy" } }
    }
    authorizer_handoff = {
      api_id        = "abc123"
      execution_arn = "arn:aws:execute-api:us-east-1:123456789012:abc123"
      authorizer_id = "auth123"
      environment   = "staging"
    }
    gateway_allowed_origins = ["https://staging.example.invalid"]
  }

  assert {
    condition     = output.namespace == "oficina-staging" && output.listener_port == 8080
    error_message = "Staging must not bind the production namespace or listener port."
  }
}
