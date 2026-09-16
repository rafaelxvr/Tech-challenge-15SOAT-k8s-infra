locals {
  name           = "${var.name}-${var.environment}"
  route_contract = jsondecode(file("${path.module}/contracts/phase3-v2/routes.json"))
  allowed_routes = {
    for route in local.route_contract.routes : "${route.method} ${route.path}" => route
    if route.decision == "ALLOW"
  }
  app_routes = {
    for route_key, route in local.allowed_routes : route_key => route
    if route.owner == "APP"
  }
  function_routes = {
    "POST /api/auth/cpf/desafios"  = "challenge"
    "POST /api/auth/cpf/verificar" = "verification"
  }
  public_app_routes = toset([
    "GET /health",
    "POST /api/auth/login",
  ])
  function_arns = {
    challenge    = var.function_arns.challenge
    verification = var.function_arns.verification
  }
  tags = {
    project     = "oficina-phase3"
    environment = var.environment
    managedBy   = "oficina-k8s-infra"
  }
}

resource "aws_lb_target_group" "app" {
  name        = substr("${local.name}-app", 0, 32)
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    path                = "/api/actuator/health/readiness"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = local.tags
}

# The foundation listener defaults to 503. This catch-all rule is the only
# route that forwards an environment listener and it owns no target attachment.
resource "aws_lb_listener_rule" "backend" {
  listener_arn = var.backend_listener_arn
  priority     = 100
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
  condition {
    path_pattern { values = ["/*"] }
  }
  tags = local.tags
}

resource "aws_apigatewayv2_api" "this" {
  name                         = "${local.name}-http-api"
  protocol_type                = "HTTP"
  disable_execute_api_endpoint = false
  cors_configuration {
    allow_credentials = false
    allow_headers     = ["Authorization", "Content-Type", "X-Gateway-Request-Id"]
    allow_methods     = ["DELETE", "GET", "OPTIONS", "POST", "PUT"]
    allow_origins     = var.cors_allow_origins
    max_age           = 300
  }
  tags = local.tags

  lifecycle {
    precondition {
      condition = alltrue([
        for arn in values(var.function_arns) :
        can(regex("^arn:aws:lambda:${var.aws_region}:[0-9]{12}:function:oficina-${var.environment}-", arn))
      ])
      error_message = "Each authorizer and CPF function must belong to the same reviewed environment as this HTTP API."
    }
  }
}

resource "aws_apigatewayv2_integration" "backend" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = var.backend_listener_arn
  connection_type        = "VPC_LINK"
  connection_id          = var.vpc_link_id
  payload_format_version = "1.0"
  request_parameters = {
    "overwrite:path"                        = "$request.path"
    "overwrite:header.X-Gateway-Request-Id" = "$context.requestId"
  }
}

resource "aws_apigatewayv2_integration" "health" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "GET"
  integration_uri        = var.backend_listener_arn
  connection_type        = "VPC_LINK"
  connection_id          = var.vpc_link_id
  payload_format_version = "1.0"
  request_parameters = {
    "overwrite:path"                        = "/api/actuator/health/readiness"
    "overwrite:header.X-Gateway-Request-Id" = "$context.requestId"
  }
}

resource "aws_apigatewayv2_integration" "function" {
  for_each               = local.function_arns
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${each.value}/invocations"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_authorizer" "request" {
  api_id                            = aws_apigatewayv2_api.this.id
  name                              = "${local.name}-request-authorizer"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${var.function_arns.authorizer}/invocations"
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  authorizer_result_ttl_in_seconds  = 0
}

# There is deliberately no catch-all route. The v2 default decision is DENY,
# and every route published here is an explicit immutable-contract allow.
resource "aws_apigatewayv2_route" "app" {
  for_each = local.app_routes

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.key
  target             = "integrations/${each.key == "GET /health" ? aws_apigatewayv2_integration.health.id : aws_apigatewayv2_integration.backend.id}"
  authorization_type = contains(local.public_app_routes, each.key) ? "NONE" : "CUSTOM"
  authorizer_id      = contains(local.public_app_routes, each.key) ? null : aws_apigatewayv2_authorizer.request.id
}

resource "aws_apigatewayv2_route" "function" {
  for_each = local.function_routes

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.function[each.value].id}"
  authorization_type = "NONE"
}

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    detailed_metrics_enabled = true
    throttling_rate_limit    = 1
    throttling_burst_limit   = 2
  }
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.gateway.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      routeKey           = "$context.routeKey"
      status             = "$context.status"
      responseLatency    = "$context.responseLatency"
      integrationLatency = "$context.integrationLatency"
      authorizerError    = "$context.authorizer.error"
    })
  }
  tags = local.tags
}

resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = 1
  tags              = local.tags
}

resource "aws_lambda_permission" "authorizer" {
  statement_id  = "AllowHttpApiAuthorizer-${var.environment}"
  action        = "lambda:InvokeFunction"
  function_name = var.function_arns.authorizer
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.request.id}"
}

resource "aws_lambda_permission" "auth_route" {
  for_each = local.function_routes

  statement_id  = "AllowHttpApi${title(each.value)}-${var.environment}"
  action        = "lambda:InvokeFunction"
  function_name = local.function_arns[each.value]
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/${split(" ", each.key)[0]}${split(" ", each.key)[1]}"
}

# This grants only Kubernetes API authentication. The rendered namespace Role
# then limits the CodeBuild principal to the objects it can deploy.
resource "aws_eks_access_entry" "deployer" {
  cluster_name  = var.cluster_name
  principal_arn = var.deployer_principal_arn
  type          = "STANDARD"
}
