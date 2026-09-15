provider "aws" {
  region = var.aws_region
}

module "bootstrap" {
  source = "../modules/bootstrap"

  account_id               = var.account_id
  state_bucket_name        = var.state_bucket_name
  artifact_bucket_name     = var.artifact_bucket_name
  github_oidc_provider_arn = var.github_oidc_provider_arn
  state_keys               = var.state_keys
  launchers                = var.launchers
  runtime_role_arns        = var.runtime_role_arns
}
