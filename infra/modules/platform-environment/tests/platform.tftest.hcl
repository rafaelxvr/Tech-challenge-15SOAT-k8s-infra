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
    function_arns = {
      authorizer   = "arn:aws:lambda:us-east-1:123456789012:function:oficina-staging-authorizer"
      challenge    = "arn:aws:lambda:us-east-1:123456789012:function:oficina-staging-challenge"
      verification = "arn:aws:lambda:us-east-1:123456789012:function:oficina-staging-verification"
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
    condition     = aws_apigatewayv2_authorizer.request.authorizer_type == "REQUEST" && aws_apigatewayv2_authorizer.request.authorizer_payload_format_version == "2.0" && aws_apigatewayv2_authorizer.request.enable_simple_responses && aws_apigatewayv2_authorizer.request.authorizer_result_ttl_in_seconds == 0
    error_message = "Every protected v2 route must use the no-cache Lambda REQUEST authorizer."
  }
  assert {
    condition     = aws_apigatewayv2_route.app["GET /api/admin/relatorios/ordens"].authorization_type == "CUSTOM" && aws_apigatewayv2_route.app["GET /api/ordens-servico/{numero}/acompanhamento"].authorization_type == "CUSTOM" && aws_apigatewayv2_route.app["POST /api/auth/login"].authorization_type == "NONE"
    error_message = "The phase3-v2 report and customer routes must be protected while the documented staff-login route remains public."
  }
  assert {
    condition     = length(aws_apigatewayv2_route.function) == 2 && aws_apigatewayv2_route.function["POST /api/auth/cpf/desafios"].authorization_type == "NONE" && aws_apigatewayv2_route.function["POST /api/auth/cpf/verificar"].authorization_type == "NONE"
    error_message = "Only the two explicit anonymous CPF routes may invoke their Lambda integrations."
  }
  assert {
    condition     = aws_apigatewayv2_api.this.cors_configuration[0].allow_credentials == false && !contains(aws_apigatewayv2_api.this.cors_configuration[0].allow_origins, "*") && aws_apigatewayv2_stage.this.default_route_settings[0].detailed_metrics_enabled && aws_cloudwatch_log_group.gateway.retention_in_days == 1
    error_message = "Gateway CORS, metrics and safe short-lived access logs must remain bounded."
  }
  assert {
    condition     = aws_lambda_permission.authorizer.function_name == var.function_arns.authorizer && aws_lambda_permission.auth_route["POST /api/auth/cpf/desafios"].function_name == var.function_arns.challenge && aws_lambda_permission.auth_route["POST /api/auth/cpf/verificar"].function_name == var.function_arns.verification
    error_message = "API Gateway may invoke each Lambda only through its reviewed authorizer or exact route permission."
  }
}

run "cross_environment_function_is_rejected" {
  command = plan

  expect_failures = [aws_apigatewayv2_api.this]

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
    function_arns = {
      authorizer   = "arn:aws:lambda:us-east-1:123456789012:function:oficina-production-authorizer"
      challenge    = "arn:aws:lambda:us-east-1:123456789012:function:oficina-production-challenge"
      verification = "arn:aws:lambda:us-east-1:123456789012:function:oficina-production-verification"
    }
    cors_allow_origins = ["https://staging.example.invalid"]
  }
}
