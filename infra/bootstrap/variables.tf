variable "aws_region" {
  type        = string
  description = "AWS deployment region. Phase 3 is designed for us-east-1."

  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "Phase 3 bootstrap is approved only for us-east-1."
  }
}

variable "account_id" { type = string }
variable "state_bucket_name" { type = string }
variable "artifact_bucket_name" { type = string }
variable "github_oidc_provider_arn" { type = string }
variable "state_keys" { type = map(string) }
variable "launchers" {
  type = map(object({
    repository                        = string
    environment                       = string
    branch                            = string
    source_prefix                     = string
    codebuild_project_arn             = string
    additional_codebuild_project_arns = optional(set(string), [])
  }))
}
variable "runtime_role_arns" {
  type    = set(string)
  default = []
}
