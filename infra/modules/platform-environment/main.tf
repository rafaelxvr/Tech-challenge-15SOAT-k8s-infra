locals {
  name = "${var.name}-${var.environment}"
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
  name          = "${local.name}-http-api"
  protocol_type = "HTTP"
  tags          = local.tags
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

resource "aws_apigatewayv2_route" "backend" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.backend.id}"
}

resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.health.id}"
}

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    throttling_rate_limit  = 1
    throttling_burst_limit = 2
  }
  tags = local.tags
}

# This grants only Kubernetes API authentication. The rendered namespace Role
# then limits the CodeBuild principal to the objects it can deploy.
resource "aws_eks_access_entry" "deployer" {
  cluster_name  = var.cluster_name
  principal_arn = var.deployer_principal_arn
  type          = "STANDARD"
}
