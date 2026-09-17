provider "aws" { region = var.aws_region }

locals {
  eks_assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "eks.amazonaws.com" } }]
  })
  ec2_assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
  oidc_host = trimprefix(module.cluster.cluster_oidc_issuer, "https://")
  load_balancer_controller_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OnlyAwsLoadBalancerController"
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = module.cluster.cluster_oidc_provider_arn }
      Condition = { StringEquals = {
        "${local.oidc_host}:aud" = "sts.amazonaws.com"
        "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
      } }
    }]
  })
}

module "network" {
  source                = "../modules/network"
  name                  = var.name
  aws_region            = var.aws_region
  vpc_cidr              = var.vpc_cidr
  availability_zones    = var.availability_zones
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  database_subnet_cidrs = var.database_subnet_cidrs
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.name}-eks-cluster"
  assume_role_policy = local.eks_assume_role_policy
}
resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}
resource "aws_iam_role" "eks_workers" {
  name               = "${var.name}-eks-workers"
  assume_role_policy = local.ec2_assume_role_policy
}
resource "aws_iam_role_policy_attachment" "eks_workers" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  ])
  role       = aws_iam_role.eks_workers.name
  policy_arn = each.value
}

module "cluster" {
  source                   = "../modules/cluster"
  name                     = var.name
  aws_region               = var.aws_region
  vpc_id                   = module.network.vpc_id
  private_subnets_by_az    = zipmap(var.availability_zones, module.network.private_subnet_ids)
  cluster_role_arn         = aws_iam_role.eks_cluster.arn
  node_role_arn            = aws_iam_role.eks_workers.arn
  oidc_thumbprint          = var.oidc_thumbprint
  node_ami_release_version = var.node_ami_release_version
  vpc_cni_addon_version    = var.vpc_cni_addon_version
  coredns_addon_version    = var.coredns_addon_version
}

# One internal ALB and one VPC link serve both isolated environments. Listener
# defaults are deliberately 503 until each environment module adds its only
# catch-all forwarding rule to an IP target group.
resource "aws_security_group" "internal_alb" {
  name        = "${var.name}-internal-alb"
  description = "Internal Oficina ALB; listeners accept traffic only from the VPC link."
  vpc_id      = module.network.vpc_id
  tags        = { project = "oficina-phase3", managedBy = "oficina-k8s-infra" }
}

resource "aws_security_group" "vpc_link" {
  name        = "${var.name}-http-api-vpc-link"
  description = "HTTP API private integration egress only to the internal ALB."
  vpc_id      = module.network.vpc_id
  tags        = { project = "oficina-phase3", managedBy = "oficina-k8s-infra" }
}

resource "aws_vpc_security_group_egress_rule" "vpc_link_to_alb" {
  security_group_id            = aws_security_group.vpc_link.id
  referenced_security_group_id = aws_security_group.internal_alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8081
  description                  = "The VPC link may reach only the two private ALB listener ports."
}

resource "aws_vpc_security_group_egress_rule" "alb_to_cluster" {
  security_group_id            = aws_security_group.internal_alb.id
  referenced_security_group_id = module.cluster.cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "The internal ALB may reach registered application pod IPs only."
}

resource "aws_vpc_security_group_ingress_rule" "vpc_link_to_alb" {
  for_each                     = { staging = 8080, production = 8081 }
  security_group_id            = aws_security_group.internal_alb.id
  referenced_security_group_id = aws_security_group.vpc_link.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "Only the VPC link may reach the ${each.key} private ALB listener."
}

resource "aws_vpc_security_group_ingress_rule" "alb_to_cluster" {
  security_group_id            = module.cluster.cluster_security_group_id
  referenced_security_group_id = aws_security_group.internal_alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "Only the internal ALB may reach registered application pod IPs."
}

resource "aws_lb" "internal" {
  name               = substr("${var.name}-internal", 0, 32)
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.internal_alb.id]
  subnets            = module.network.public_subnet_ids
  idle_timeout       = 60
  tags               = { project = "oficina-phase3", managedBy = "oficina-k8s-infra" }
}

resource "aws_lb_listener" "backend" {
  for_each          = { staging = 8080, production = 8081 }
  load_balancer_arn = aws_lb.internal.arn
  port              = each.value
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "No ready Oficina ${each.key} target is bound."
      status_code  = "503"
    }
  }
  tags = { project = "oficina-phase3", environment = each.key, managedBy = "oficina-k8s-infra" }
}

resource "aws_apigatewayv2_vpc_link" "internal" {
  name               = "${var.name}-internal-alb"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = module.network.private_subnet_ids
  tags               = { project = "oficina-phase3", managedBy = "oficina-k8s-infra" }
}

resource "aws_iam_role" "load_balancer_controller" {
  name               = "${var.name}-aws-load-balancer-controller"
  assume_role_policy = local.load_balancer_controller_trust
  tags               = { project = "oficina-phase3", managedBy = "oficina-k8s-infra" }
}

# TargetGroupBinding is the only supported controller path. It may discover
# VPC resources and maintain targets/health attributes in tagged target groups;
# it has no IAM permission to create listeners, load balancers or target groups.
resource "aws_iam_role_policy" "load_balancer_controller" {
  name = "target-group-binding-only"
  role = aws_iam_role.load_balancer_controller.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DiscoverOnly"
        Effect   = "Allow"
        Action   = ["ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "ec2:DescribeNetworkInterfaces", "elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeListeners", "elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTargetHealth"]
        Resource = "*"
      },
      {
        Sid      = "RegisterOnlyTaggedPlatformTargets"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets", "elasticloadbalancing:ModifyTargetGroup", "elasticloadbalancing:ModifyTargetGroupAttributes"]
        Resource = "arn:aws:elasticloadbalancing:${var.aws_region}:*:targetgroup/*"
        Condition = { StringEquals = {
          "aws:ResourceTag/project" = "oficina-phase3"
        } }
      }
    ]
  })
}

# A separate reviewed platform role applies the immutable target-group binding.
# Application release roles never receive this EKS access entry or its RBAC.
resource "aws_eks_access_entry" "platform_binding" {
  cluster_name  = module.cluster.cluster_name
  principal_arn = var.platform_binding_principal_arn
  type          = "STANDARD"
}

resource "aws_security_group" "codebuild" {
  name        = "${var.name}-codebuild"
  description = "Outbound-only group for short-lived private deployment jobs."
  vpc_id      = module.network.vpc_id
  egress {
    description = "TLS to reviewed AWS services through the single NAT or gateway endpoint route."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "codebuild_to_private_cluster_api" {
  type                     = "ingress"
  security_group_id        = module.cluster.cluster_security_group_id
  source_security_group_id = aws_security_group.codebuild.id
  protocol                 = "tcp"
  from_port                = 443
  to_port                  = 443
  description              = "Only private CodeBuild executor traffic may call the cluster API."
}

# Lambda functions share one foundation-owned group. It can call AWS service
# APIs over TLS and the database only through the reviewed database group.
resource "aws_security_group" "lambda" {
  name        = "${var.name}-functions"
  description = "Private Lambda egress is limited to TLS service APIs and PostgreSQL in the reviewed database group."
  vpc_id      = module.network.vpc_id
  tags        = { project = "oficina-phase3", managedBy = "oficina-k8s-infra", component = "functions" }
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds"
  description = "Managed PostgreSQL accepts traffic only from the foundation Lambda security group."
  vpc_id      = module.network.vpc_id
  tags        = { project = "oficina-phase3", managedBy = "oficina-k8s-infra", component = "database" }
}

resource "aws_vpc_security_group_egress_rule" "functions_to_aws_apis" {
  security_group_id = aws_security_group.lambda.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Functions may use TLS only for reviewed AWS service APIs through the private NAT path."
}

resource "aws_vpc_security_group_egress_rule" "functions_to_database" {
  security_group_id            = aws_security_group.lambda.id
  referenced_security_group_id = aws_security_group.rds.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Functions may reach only PostgreSQL in the reviewed database group."
}

resource "aws_vpc_security_group_ingress_rule" "database_from_functions" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Only private functions may reach the managed PostgreSQL database."
}

module "deployment_executor" {
  source                            = "../modules/deployment-executor"
  name                              = var.name
  aws_region                        = var.aws_region
  account_id                        = var.account_id
  vpc_id                            = module.network.vpc_id
  cluster_arn                       = module.cluster.cluster_arn
  node_group_arns                   = module.cluster.node_group_arns
  kubernetes_repository             = var.kubernetes_repository
  artifact_bucket_name              = var.artifact_bucket_name
  state_bucket_name                 = var.state_bucket_name
  private_subnet_ids                = module.network.private_subnet_ids
  security_group_ids                = [aws_security_group.codebuild.id]
  deployer_image_digest             = var.deployer_image_digest
  function_gateway_bindings         = var.function_gateway_bindings
  newrelic_layer_version_arns       = var.newrelic_layer_version_arns
  deployments                       = var.deployments
  application_bootstrap_secret_refs = var.application_bootstrap_secret_refs
}

# This executor is intentionally outside the eight application-repository
# projects. It owns the separate root that applies the reviewed cluster-wide
# Helm addons through the private EKS endpoint.
module "foundation_addons_executor" {
  source                            = "../modules/foundation-addons-executor"
  name                              = var.name
  aws_region                        = var.aws_region
  account_id                        = var.account_id
  cluster_name                      = module.cluster.cluster_name
  cluster_arn                       = module.cluster.cluster_arn
  cluster_endpoint                  = module.cluster.cluster_endpoint
  cluster_ca_certificate            = module.cluster.cluster_certificate_authority_data
  vpc_id                            = module.network.vpc_id
  private_subnet_ids                = module.network.private_subnet_ids
  security_group_ids                = [aws_security_group.codebuild.id]
  artifact_bucket_name              = var.artifact_bucket_name
  state_bucket_name                 = var.state_bucket_name
  deployer_repository_url           = module.deployment_executor.ecr_repository_url
  deployer_image_digest             = var.deployer_image_digest
  vpc_id_for_controller             = module.network.vpc_id
  load_balancer_controller_role_arn = aws_iam_role.load_balancer_controller.arn
}
