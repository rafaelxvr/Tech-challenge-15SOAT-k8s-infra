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
  private_subnet_ids    = module.network.private_subnet_ids
  security_group_ids    = [aws_security_group.codebuild.id]
  deployer_image_digest = var.deployer_image_digest
  deployments           = var.deployments
}
