mock_provider "aws" {}

variables {
  name                     = "oficina-phase3"
  aws_region               = "us-east-1"
  vpc_id                   = "vpc-12345678"
  private_subnets_by_az    = { "us-east-1a" = "subnet-a", "us-east-1b" = "subnet-b" }
  cluster_role_arn         = "arn:aws:iam::123456789012:role/oficina-eks-cluster"
  node_role_arn            = "arn:aws:iam::123456789012:role/oficina-eks-workers"
  oidc_thumbprint          = "0123456789012345678901234567890123456789"
  node_ami_release_version = "1.35.0-20260901"
  vpc_cni_addon_version    = "v1.21.0-eksbuild.1"
  coredns_addon_version    = "v1.12.0-eksbuild.1"
}

run "private_api_two_fixed_workers_and_minimal_updates" {
  command = plan

  assert {
    condition     = aws_eks_cluster.this.version == "1.35" && aws_eks_cluster.this.vpc_config[0].endpoint_private_access && !aws_eks_cluster.this.vpc_config[0].endpoint_public_access
    error_message = "EKS must expose a private-only 1.35 API."
  }
  assert {
    condition = alltrue([for n in aws_eks_node_group.workers :
      n.scaling_config[0].min_size == 1 &&
      n.scaling_config[0].desired_size == 1 &&
      n.scaling_config[0].max_size == 1 &&
      n.update_config[0].max_unavailable == 1 &&
      local.node_update_strategy == "MINIMAL"
    ])
    error_message = "A surge node would exceed the observed vCPU quota."
  }
  assert {
    condition     = length(aws_eks_node_group.workers) == 2 && alltrue([for n in aws_eks_node_group.workers : n.instance_types[0] == "m7i-flex.large" && n.disk_size == 20 && n.ami_type == "AL2023_x86_64_STANDARD" && n.update_config[0].max_unavailable == 1])
    error_message = "Each AZ needs exactly one fixed AL2023 m7i-flex.large worker with a 20 GiB gp3 volume."
  }
  assert {
    condition     = can(regex("enableNetworkPolicy", aws_eks_addon.vpc_cni.configuration_values)) && length(var.oidc_thumbprint) == 40
    error_message = "VPC CNI network-policy enforcement must be enabled at the add-on, not only in YAML."
  }
  assert {
    condition     = terraform_data.workers_minimal_update.triggers_replace.update_strategy == "MINIMAL" && terraform_data.workers_minimal_update.triggers_replace.max_unavailable == 1 && can(regex("workers-", terraform_data.workers_minimal_update.triggers_replace.node_group_release_versions_json))
    error_message = "Version changes must be delegated to the serial MINIMAL EKS API executor before replacement can begin."
  }
}
