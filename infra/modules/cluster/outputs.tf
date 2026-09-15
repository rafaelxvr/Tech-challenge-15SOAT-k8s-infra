output "cluster_name" { value = aws_eks_cluster.this.name }
output "cluster_arn" { value = aws_eks_cluster.this.arn }
output "cluster_oidc_provider_arn" { value = aws_iam_openid_connect_provider.cluster.arn }
output "cluster_security_group_id" { value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id }
output "cluster_endpoint" { value = aws_eks_cluster.this.endpoint }
output "cluster_certificate_authority_data" { value = aws_eks_cluster.this.certificate_authority[0].data }
output "node_group_names" { value = { for az, group in aws_eks_node_group.workers : az => group.node_group_name } }
output "aws_node_irsa_role_arn" { value = aws_iam_role.aws_node_irsa.arn }
output "aws_node_irsa_trust_policy" { value = local.aws_node_irsa_trust }
