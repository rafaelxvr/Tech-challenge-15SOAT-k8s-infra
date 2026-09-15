output "ecr_repository_url" { value = aws_ecr_repository.deployer.repository_url }
output "codebuild_projects" {
  value = {
    for key, project in aws_codebuild_project.deploy : key => {
      projectName = project.name
      projectArn  = project.arn
      roleName    = aws_iam_role.codebuild[key].name
      roleArn     = aws_iam_role.codebuild[key].arn
    }
  }
}
