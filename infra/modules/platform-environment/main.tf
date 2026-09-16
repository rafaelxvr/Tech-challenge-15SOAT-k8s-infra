locals {
  name = "${var.name}-${var.environment}"
  tags = {
    project     = "oficina-phase3"
    environment = var.environment
    managedBy   = "oficina-k8s-infra"
  }
}

# The shared ALB is deliberately passed from foundation. This module only adds
# its environment listener and never creates target attachments: the pinned AWS
# Load Balancer Controller owns pod registration through TargetGroupBinding.
resource "aws_lb_listener" "backend" {
  load_balancer_arn = var.internal_alb_arn
  port              = var.listener_port
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "No ready Oficina target is bound."
      status_code  = "503"
    }
  }

  tags = local.tags
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

resource "aws_security_group_rule" "vpc_link_to_listener" {
  type                     = "ingress"
  security_group_id        = var.internal_alb_security_group_id
  source_security_group_id = var.vpc_link_security_group_id
  protocol                 = "tcp"
  from_port                = var.listener_port
  to_port                  = var.listener_port
  description              = "Only the shared HTTP API VPC link may reach the ${var.environment} ALB listener."
}

resource "aws_security_group_rule" "alb_to_cluster_pods" {
  type                     = "ingress"
  security_group_id        = var.cluster_security_group_id
  source_security_group_id = var.internal_alb_security_group_id
  protocol                 = "tcp"
  from_port                = 8080
  to_port                  = 8080
  description              = "Internal ALB health and application traffic to registered ${var.environment} pod IPs."
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
  integration_uri        = aws_lb_listener.backend.arn
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
  integration_uri        = aws_lb_listener.backend.arn
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
