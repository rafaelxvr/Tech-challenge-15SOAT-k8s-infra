mock_provider "aws" {}

run "private_environment_contract" {
  command = plan

  variables {
    name                           = "oficina"
    environment                    = "staging"
    aws_region                     = "us-east-1"
    vpc_id                         = "vpc-12345678"
    cluster_name                   = "oficina"
    cluster_security_group_id      = "sg-cluster"
    internal_alb_arn               = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/oficina/1234567890abcdef"
    internal_alb_security_group_id = "sg-alb"
    vpc_link_id                    = "abc123"
    vpc_link_security_group_id     = "sg-vpclink"
    listener_port                  = 8080
    namespace                      = "oficina-staging"
    deployer_principal_arn         = "arn:aws:iam::123456789012:role/oficina-k8s-staging-deploy"
  }

  assert {
    condition     = aws_lb_target_group.app.target_type == "ip" && aws_lb_target_group.app.port == 8080 && aws_lb_target_group.app.health_check[0].path == "/api/actuator/health/readiness"
    error_message = "The controller must register pod IPs into a readiness-checked target group."
  }
  assert {
    condition     = aws_apigatewayv2_api.this.protocol_type == "HTTP" && aws_apigatewayv2_integration.backend.connection_type == "VPC_LINK" && aws_apigatewayv2_integration.backend.request_parameters["overwrite:path"] == "$request.path"
    error_message = "Business API traffic must use the private VPC link and retain its path."
  }
  assert {
    condition     = aws_apigatewayv2_integration.health.request_parameters["overwrite:path"] == "/api/actuator/health/readiness" && aws_apigatewayv2_stage.this.default_route_settings[0].throttling_rate_limit == 1
    error_message = "Health mapping and initial throttling must remain explicit."
  }
  assert {
    condition     = aws_eks_access_entry.deployer.type == "STANDARD" && aws_security_group_rule.vpc_link_to_listener.from_port == 8080
    error_message = "The deployer must be a standard access entry and the link may reach only its listener."
  }
}
