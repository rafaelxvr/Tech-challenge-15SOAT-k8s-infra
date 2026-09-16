variable "cluster_name" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9-]{1,100}$", var.cluster_name))
    error_message = "cluster_name must be bounded."
  }
}
variable "cluster_endpoint" {
  type = string
  validation {
    condition     = can(regex("^https://", var.cluster_endpoint))
    error_message = "cluster endpoint must be HTTPS."
  }
}
variable "cluster_ca_certificate" {
  type      = string
  sensitive = true
}
variable "environment" {
  type = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}
variable "ingest_secret_name" {
  type        = string
  description = "One existing environment ingest secret; R2 may not create a third AWS Secret."
  validation {
    condition     = can(regex("^newrelic-(staging|production)-ingest$", var.ingest_secret_name))
    error_message = "Use one reviewed environment ingest Secret reference."
  }
}
variable "ingest_secret_arn" {
  type        = string
  sensitive   = true
  description = "Existing environment-scoped AWS secret synchronized into the newrelic namespace; no value enters Terraform."
  validation {
    condition     = can(regex("^arn:aws:secretsmanager:us-east-1:[0-9]{12}:secret:oficina/${var.environment}/newrelic-ingest-[A-Za-z0-9/_+=.@-]+$", var.ingest_secret_arn))
    error_message = "ingest_secret_arn must be the approved existing secret for this environment."
  }
}
variable "secret_sync_irsa_role_arn" {
  type        = string
  description = "Existing least-privilege IRSA role that reads only ingest_secret_arn for CSI sync."
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.secret_sync_irsa_role_arn))
    error_message = "secret_sync_irsa_role_arn must be an existing IAM role ARN."
  }
}
variable "gateway_health_urls" {
  type = map(string)
  validation {
    condition     = length(var.gateway_health_urls) == 2 && alltrue([for env, url in var.gateway_health_urls : contains(["staging", "production"], env) && can(regex("^https://[^[:space:]]+$", url))])
    error_message = "Both environment public HTTPS gateway health URLs are required."
  }
}
variable "newrelic_account_id" {
  type = number
  validation {
    condition     = var.newrelic_account_id > 0
    error_message = "newrelic_account_id is a positive account identifier."
  }
}

variable "newrelic_api_key" {
  type        = string
  sensitive   = true
  description = "Supplied at execution by the private executor's TF_VAR_newrelic_api_key; never committed in tfvars or chart values."
  validation {
    condition     = length(trimspace(var.newrelic_api_key)) >= 8
    error_message = "The executor must supply the New Relic provider key through its protected environment."
  }
}
