variable "aws_region" {
  type = string
  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "Phase 3 foundation is approved only in us-east-1."
  }
}
variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the verified 12-digit deployment account."
  }
}
variable "name" {
  type = string
  validation {
    condition     = var.name == "oficina-phase3"
    error_message = "The reviewed Phase 3 platform name is fixed to oficina-phase3."
  }
}
variable "artifact_bucket_name" { type = string }
variable "state_bucket_name" {
  type        = string
  description = "Reviewed bootstrap state bucket consumed only for scoped executor state/lock access."
}
variable "vpc_cidr" { type = string }
variable "availability_zones" { type = list(string) }
variable "public_subnet_cidrs" { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }
variable "database_subnet_cidrs" { type = list(string) }
variable "oidc_thumbprint" { type = string }
variable "node_ami_release_version" { type = string }
variable "vpc_cni_addon_version" { type = string }
variable "coredns_addon_version" { type = string }
variable "deployer_image_digest" { type = string }
variable "kubernetes_repository" { type = string }
variable "application_bootstrap_secret_refs" {
  type = map(object({
    database_arn = string
    master       = object({ arn = string, version_id = string, database_arn = string })
    migration    = object({ arn = string, version_id = string })
    app          = object({ arn = string, version_id = string })
    auth         = object({ arn = string, version_id = string })
    notification = object({ arn = string, version_id = string })
  }))
  default     = {}
  description = "Optional reviewed APP bootstrap references passed to the application executor; empty by default."
}
variable "platform_binding_principal_arn" {
  type        = string
  description = "Dedicated reviewed IAM role used only by the trusted platform binding step; it is never an application release role."
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.platform_binding_principal_arn))
    error_message = "platform_binding_principal_arn must be the reviewed dedicated IAM role ARN."
  }
}
variable "function_gateway_api_ids" {
  type        = map(string)
  default     = {}
  description = "Reviewed HTTP API v2 ID per environment, passed to the FUN executor only after platform handoff."
}
variable "newrelic_layer_version_arns" {
  type        = object({ java_slim = string, extension = string })
  default     = null
  description = "Reviewed immutable New Relic layer version ARNs. Null intentionally withholds FUN layer-read permissions until versions are approved."
}
variable "deployments" {
  type = map(object({
    repository               = string
    environment              = string
    source_prefix            = string
    terraform_state_key      = string
    deployment_mode          = string
    terraform_variables_path = string
  }))
}
