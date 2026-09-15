output "state_bucket_name" {
  value       = aws_s3_bucket.state.bucket
  description = "Versioned, encrypted Terraform state bucket name."
}

output "artifact_bucket_name" {
  value       = aws_s3_bucket.artifact.bucket
  description = "Versioned, encrypted immutable deployment artifact bucket name."
}

output "launcher_role_arns" {
  value       = { for name, role in aws_iam_role.launcher : name => role.arn }
  description = "Per repository/environment GitHub OIDC launcher role ARNs."
}

output "launcher_trust_subjects" {
  value       = local.launcher_subjects
  description = "Exact GitHub environment subjects trusted by each launcher role."
}

output "launcher_trust_policies" {
  value       = local.launcher_trust_policies
  description = "Rendered exact audience and repository/environment trust policies for offline review."
}

output "state_access_policy_arns" {
  value       = { for name, policy in aws_iam_policy.state_access : name => policy.arn }
  description = "Unattached, per-root state and lockfile policies for the dedicated human/deployment identity."
}
