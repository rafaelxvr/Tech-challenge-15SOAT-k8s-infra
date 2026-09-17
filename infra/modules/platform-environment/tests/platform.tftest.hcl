mock_provider "aws" {}

override_resource {
  target = aws_apigatewayv2_api.this
  values = {
    id            = "abc123"
    execution_arn = "arn:aws:execute-api:us-east-1:123456789012:abc123"
  }
}

run "private_environment_contract" {
  command = plan

  variables {
    name                   = "oficina-phase3"
    environment            = "staging"
    aws_region             = "us-east-1"
    account_id             = "123456789012"
    vpc_id                 = "vpc-12345678"
    cluster_name           = "oficina"
    backend_listener_arn   = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/oficina/1234567890abcdef/abcdef1234567890"
    vpc_link_id            = "abc123"
    listener_port          = 8080
    namespace              = "oficina-staging"
    deployer_principal_arn = "arn:aws:iam::123456789012:role/oficina-k8s-staging-deploy"
    authorizer_handoff = {
      api_id        = "abc123"
      execution_arn = "arn:aws:execute-api:us-east-1:123456789012:abc123"
      authorizer_id = "auth123"
      environment   = "staging"
    }
    cors_allow_origins = ["https://staging.example.invalid"]
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
  assert {
    condition     = aws_apigatewayv2_route.app["GET /api/admin/relatorios/ordens"].authorization_type == "CUSTOM" && aws_apigatewayv2_route.app["GET /api/ordens-servico/{numero}/acompanhamento"].authorization_type == "CUSTOM" && aws_apigatewayv2_route.app["POST /api/auth/login"].authorization_type == "NONE"
    error_message = "The phase3-v2 report and customer routes must be protected while the documented staff-login route remains public."
  }
  assert {
    condition     = aws_apigatewayv2_api.this.cors_configuration[0].allow_credentials == false && !contains(aws_apigatewayv2_api.this.cors_configuration[0].allow_origins, "*") && aws_apigatewayv2_stage.this.default_route_settings[0].detailed_metrics_enabled && aws_cloudwatch_log_group.gateway.retention_in_days == 1
    error_message = "Gateway CORS, metrics and safe short-lived access logs must remain bounded."
  }
  assert {
    condition     = aws_apigatewayv2_route.app["GET /api/admin/relatorios/ordens"].authorizer_id == var.authorizer_handoff.authorizer_id
    error_message = "Protected APP routes must bind the authorizer supplied by the FUN handoff."
  }
}

run "cross_environment_or_api_mismatch_is_rejected" {
  command = plan

  expect_failures = [var.authorizer_handoff]

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
    account_id             = "123456789012"
    authorizer_handoff = {
      api_id        = "different123"
      execution_arn = "arn:aws:execute-api:us-east-1:123456789012:abc123"
      authorizer_id = "auth123"
      environment   = "staging"
    }
    cors_allow_origins = ["https://staging.example.invalid"]
  }
}

run "initial_apply_has_only_safe_public_app_routes" {
  command = plan

  variables {
    name                   = "oficina-phase3"
    environment            = "staging"
    aws_region             = "us-east-1"
    account_id             = "123456789012"
    vpc_id                 = "vpc-12345678"
    cluster_name           = "oficina"
    backend_listener_arn   = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/oficina/1234567890abcdef/abcdef1234567890"
    vpc_link_id            = "abc123"
    listener_port          = 8080
    namespace              = "oficina-staging"
    deployer_principal_arn = "arn:aws:iam::123456789012:role/oficina-k8s-staging-deploy"
    cors_allow_origins     = ["https://staging.example.invalid"]
  }

  assert {
    condition     = toset(keys(aws_apigatewayv2_route.app)) == toset(["GET /health", "POST /api/auth/login"])
    error_message = "The initial K8S apply may publish only the explicitly reviewed public APP routes."
  }
}
