variable "name" {
  type = string
  validation {
    condition     = var.name == "oficina-phase3"
    error_message = "The reviewed Phase 3 platform name is fixed to oficina-phase3."
  }
}
variable "environment" {
  type = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}
variable "aws_region" {
  type = string
  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "The reviewed platform is limited to us-east-1."
  }
}
variable "vpc_id" { type = string }
variable "cluster_name" { type = string }
variable "backend_listener_arn" { type = string }
variable "vpc_link_id" { type = string }
variable "listener_port" {
  type = number
  validation {
    condition     = var.listener_port == (var.environment == "staging" ? 8080 : 8081)
    error_message = "Use listener port 8080 for staging and 8081 for production."
  }
}
variable "deployer_principal_arn" {
  type        = string
  description = "The exact environment CodeBuild role ARN added as a standard EKS access entry."
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.deployer_principal_arn))
    error_message = "deployer_principal_arn must be a reviewed IAM role ARN."
  }
}
variable "namespace" {
  type = string
  validation {
    condition     = var.namespace == "oficina-${var.environment}"
    error_message = "namespace must match the isolated environment name."
  }
}
variable "authorizer_id" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional API Gateway authorizer ID from the FUN handoff. Protected APP routes are created only when this is supplied."
  validation {
    condition     = var.authorizer_id == null || can(regex("^[A-Za-z0-9]+$", var.authorizer_id))
    error_message = "authorizer_id must be the reviewed API Gateway authorizer ID from the FUN handoff."
  }
}
variable "cors_allow_origins" {
  type        = set(string)
  description = "Explicit reviewed HTTPS browser origins. Wildcard origins and credentials are prohibited."
  validation {
    condition = length(var.cors_allow_origins) > 0 && alltrue([
      for origin in var.cors_allow_origins : can(regex("^https://[A-Za-z0-9][A-Za-z0-9.-]*(?::[0-9]{1,5})?$", origin))
    ])
    error_message = "cors_allow_origins must contain explicit HTTPS origins only; wildcard, HTTP, path and query origins are prohibited."
  }
}
