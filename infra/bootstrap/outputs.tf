output "state_bucket_name" { value = module.bootstrap.state_bucket_name }
output "artifact_bucket_name" { value = module.bootstrap.artifact_bucket_name }
output "launcher_role_arns" { value = module.bootstrap.launcher_role_arns }
output "launcher_trust_subjects" { value = module.bootstrap.launcher_trust_subjects }
output "launcher_trust_policies" { value = module.bootstrap.launcher_trust_policies }
output "state_access_policy_arns" { value = module.bootstrap.state_access_policy_arns }
output "foundation_output_publisher_policy_arn" { value = module.bootstrap.foundation_output_publisher_policy_arn }
