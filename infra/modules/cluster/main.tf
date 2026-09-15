locals {
  oidc_host = trimprefix(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://")
  tags      = { project = "oficina-phase3" }
  # aws provider 5.100.0 exposes max_unavailable but not EKS's updateStrategy.
  # The terraform_data executor below calls EKS's supported API before a version update.
  node_update_strategy = "MINIMAL"
  aws_node_irsa_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OnlyAwsNodeServiceAccount"
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.cluster.arn }
      Condition = { StringEquals = {
        "${local.oidc_host}:aud" = "sts.amazonaws.com"
        "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:aws-node"
      } }
    }]
  })
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = var.cluster_role_arn
  version  = "1.35"

  vpc_config {
    subnet_ids              = values(var.private_subnets_by_az)
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  access_config { authentication_mode = "API_AND_CONFIG_MAP" }
  enabled_cluster_log_types = ["api", "audit", "authenticator"]
  tags                      = local.tags
}

resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [var.oidc_thumbprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  tags            = local.tags
}

resource "aws_iam_role" "aws_node_irsa" {
  name               = "${var.name}-aws-node-irsa"
  assume_role_policy = local.aws_node_irsa_trust
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "aws_node_irsa" {
  role       = aws_iam_role.aws_node_irsa.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = var.vpc_cni_addon_version
  service_account_role_arn    = aws_iam_role.aws_node_irsa.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  configuration_values        = jsonencode({ enableNetworkPolicy = "true" })
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = var.coredns_addon_version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}

resource "aws_eks_node_group" "workers" {
  for_each        = var.private_subnets_by_az
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "workers-${replace(each.key, var.aws_region, "")}"
  node_role_arn   = var.node_role_arn
  subnet_ids      = [each.value]
  ami_type        = "AL2023_x86_64_STANDARD"
  release_version = var.node_ami_release_version
  capacity_type   = "ON_DEMAND"
  instance_types  = ["m7i-flex.large"]
  disk_size       = 20

  scaling_config {
    min_size     = 1
    desired_size = 1
    max_size     = 1
  }
  update_config {
    max_unavailable = 1
  }
  lifecycle {
    # Version changes are applied only by workers_minimal_update. Letting the
    # provider update this field would use EKS's DEFAULT surge strategy first.
    ignore_changes = [release_version]
  }
  tags = local.tags
}

resource "terraform_data" "workers_minimal_update" {
  triggers_replace = {
    cluster_name                     = aws_eks_cluster.this.name
    node_group_release_versions_json = jsonencode({ for az, group in aws_eks_node_group.workers : group.node_group_name => var.node_ami_release_version })
    max_unavailable                  = 1
    update_strategy                  = local.node_update_strategy
  }

  depends_on = [aws_eks_node_group.workers]

  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoLogo", "-NoProfile", "-File"]
    command     = "${path.module}/scripts/apply-minimal-node-update.ps1 -Region ${var.aws_region} -ClusterName ${aws_eks_cluster.this.name} -NodeGroupReleaseVersionsJson '${self.triggers_replace.node_group_release_versions_json}' -UpdateStrategy ${local.node_update_strategy} -MaxUnavailable 1"
  }
}

resource "terraform_data" "fixed_two_node_capacity" {
  input = { node_groups = keys(aws_eks_node_group.workers), update_strategy = local.node_update_strategy }
  lifecycle {
    precondition {
      condition     = length(var.private_subnets_by_az) == 2 && length(aws_eks_node_group.workers) == 2
      error_message = "The approved cluster has exactly one fixed worker group in each of two AZs."
    }
    precondition {
      condition     = local.node_update_strategy == "MINIMAL"
      error_message = "Node updates must use the reviewed MINIMAL strategy through the private deployment executor."
    }
  }
}
