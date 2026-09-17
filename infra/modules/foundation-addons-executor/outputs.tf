output "project_name" { value = aws_codebuild_project.foundation_addons.name }
output "project_arn" { value = aws_codebuild_project.foundation_addons.arn }
output "role_arn" { value = aws_iam_role.foundation_addons.arn }
output "state_key" { value = local.state_key }
