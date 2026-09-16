mock_provider "aws" {}

run "private_environment_contract" {
  command = plan

  variables {
    name                   = "oficina-phase3"
    environment            = "staging"
    aws_region             = "us-east-1"
    vpc_id                 = "vpc-12345678"
    cluster_name           = "oficina"
    backend_listener_arn   = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/oficina/1234567890abcdef/abcdef1234567890"
    vpc_link_id            = "abc123"
    listener_port          = 8080
    namespace              = "oficina-staging"
    deployer_principal_arn = "arn:aws:iam::123456789012:role/oficina-k8s-staging-deploy"
  }

  assert {
    condition     = aws_lb_target_group.app.name == "oficina-phase3-staging-app" && aws_lb_target_group.app.target_type == "ip" && aws_lb_target_group.app.port == 8080 && aws_lb_target_group.app.health_check[0].path == "/api/actuator/health/readiness"
    error_message = "The controller must register pod IPs into the reviewed fixed-name, readiness-checked target group."
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
    condition     = aws_eks_access_entry.deployer.type == "STANDARD" && aws_lb_listener_rule.backend.listener_arn == var.backend_listener_arn && aws_lb_listener_rule.backend.action[0].type == "forward" && length(aws_lb_listener_rule.backend.condition) == 1 && alltrue([for condition in aws_lb_listener_rule.backend.condition : length(condition.path_pattern) == 1])
    error_message = "The deployer must be standard and the listener must forward every environment path to its target group."
  }
}
