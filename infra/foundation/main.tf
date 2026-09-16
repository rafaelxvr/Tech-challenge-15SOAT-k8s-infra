provider "aws" { region = var.aws_region }

provider "helm" {
  kubernetes {
    host                   = module.cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--region", var.aws_region, "--cluster-name", module.cluster.cluster_name]
    }
  }
}

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
  ingress     = []
  egress      = []
  tags        = { project = "oficina-phase3", managedBy = "oficina-k8s-infra" }
}

resource "aws_security_group" "vpc_link" {
  name        = "${var.name}-http-api-vpc-link"
  description = "HTTP API private integration egress only to the internal ALB."
  vpc_id      = module.network.vpc_id
  ingress     = []
  egress      = []
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

resource "helm_release" "aws_load_balancer_controller" {
  name             = "aws-load-balancer-controller"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = "1.12.0"
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600
  values = [yamlencode({
    clusterName = module.cluster.cluster_name
    region      = var.aws_region
    vpcId       = module.network.vpc_id
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.load_balancer_controller.arn
      }
    }
    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { cpu = "250m", memory = "256Mi" }
    }
  })]
  depends_on = [aws_iam_role_policy.load_balancer_controller, module.cluster]
}

resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  chart            = "metrics-server"
  version          = "3.12.2"
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600
  values = [yamlencode({
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "100m", memory = "128Mi" }
    }
  })]
  depends_on = [module.cluster]
}

resource "helm_release" "secrets_store_csi_driver" {
  name             = "secrets-store-csi-driver"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart            = "secrets-store-csi-driver"
  version          = "1.4.8"
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600
  values = [yamlencode({
    syncSecret           = { enabled = true }
    enableSecretRotation = false
    linux = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "100m", memory = "128Mi" }
      }
    }
  })]
  depends_on = [module.cluster]
}

resource "helm_release" "secrets_store_csi_aws_provider" {
  name             = "secrets-store-csi-driver-provider-aws"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart            = "secrets-store-csi-driver-provider-aws"
  version          = "0.3.9"
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600
  values = [yamlencode({
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "100m", memory = "128Mi" }
    }
  })]
  depends_on = [helm_release.secrets_store_csi_driver]
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

module "deployment_executor" {
  source                = "../modules/deployment-executor"
  name                  = var.name
  aws_region            = var.aws_region
  account_id            = var.account_id
  vpc_id                = module.network.vpc_id
  cluster_arn           = module.cluster.cluster_arn
  node_group_arns       = module.cluster.node_group_arns
  kubernetes_repository = var.kubernetes_repository
  artifact_bucket_name  = var.artifact_bucket_name
  state_bucket_name     = var.state_bucket_name
  private_subnet_ids    = module.network.private_subnet_ids
  security_group_ids    = [aws_security_group.codebuild.id]
  deployer_image_digest = var.deployer_image_digest
  deployments           = var.deployments
}
