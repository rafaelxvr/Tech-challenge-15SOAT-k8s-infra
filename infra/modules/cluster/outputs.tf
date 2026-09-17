output "cluster_name" { value = aws_eks_cluster.this.name }
output "cluster_arn" { value = aws_eks_cluster.this.arn }
output "cluster_oidc_provider_arn" { value = aws_iam_openid_connect_provider.cluster.arn }
output "cluster_oidc_issuer" { value = aws_eks_cluster.this.identity[0].oidc[0].issuer }
output "cluster_security_group_id" { value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id }
output "cluster_endpoint" { value = aws_eks_cluster.this.endpoint }
output "cluster_certificate_authority_data" { value = aws_eks_cluster.this.certificate_authority[0].data }
output "node_group_names" { value = { for az, group in aws_eks_node_group.workers : az => group.node_group_name } }
output "node_group_arns" { value = [for group in aws_eks_node_group.workers : group.arn] }
output "node_update_control" {
  value = {
    strategy         = local.node_update_strategy
    maxUnavailable   = 1
    executorScript   = "scripts/apply-minimal-node-update.ps1"
    releaseManagedBy = "workers_minimal_update"
  }
}
output "aws_node_irsa_role_arn" { value = aws_iam_role.aws_node_irsa.arn }
output "aws_node_irsa_trust_policy" { value = local.aws_node_irsa_trust }
