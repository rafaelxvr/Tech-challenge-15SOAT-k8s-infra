variable "name" { type = string }
variable "aws_region" { type = string }
variable "account_id" { type = string }
variable "vpc_id" { type = string }
variable "cluster_arn" { type = string }
variable "artifact_bucket_name" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "security_group_ids" { type = list(string) }
variable "deployer_image_digest" {
  type        = string
  description = "Immutable SHA-256 digest produced by the reviewed GitHub platform-image workflow."
  validation {
    condition     = can(regex("^sha256:[a-f0-9]{64}$", var.deployer_image_digest))
    error_message = "deployer_image_digest must be a lowercase immutable SHA-256 image digest."
  }
}
variable "deployments" {
  type = map(object({
    repository    = string
    environment   = string
    source_prefix = string
  }))
  description = "Exactly four repositories multiplied by staging and production. Source bundles arrive through S3, never GitHub credentials in CodeBuild."
  validation {
    condition = length(var.deployments) == 8 && length(distinct([for deployment in values(var.deployments) : deployment.repository])) == 4 && alltrue([
      for deployment in values(var.deployments) :
      contains(["staging", "production"], deployment.environment) &&
      can(regex("^[a-z0-9][a-z0-9/_-]*$", deployment.source_prefix))
    ])
    error_message = "deployments must contain exactly four repositories in both reviewed environments with bounded S3 source prefixes."
  }
}
