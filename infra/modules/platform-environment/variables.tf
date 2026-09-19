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
variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the reviewed 12-digit deployment account."
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
variable "app_deployer_principal_arn" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional staging APP executor identity. Authentication only; the matching IAM-ARN User is authorized by the reviewed namespaced RoleBinding."
  validation {
    condition = var.app_deployer_principal_arn == null || (
      var.environment == "staging" &&
      var.app_deployer_principal_arn == "arn:aws:iam::${var.account_id}:role/${var.name}-oficina-app-staging-deploy-role"
    )
    error_message = "APP access is limited to the exact same-account staging APP executor role; production and other principals are forbidden."
  }
}
variable "authorizer_handoff" {
  type = object({
    api_id        = string
    execution_arn = string
    authorizer_id = string
    environment   = string
  })
  default     = null
  nullable    = true
  description = "Optional reviewed FUN handoff. Protected APP routes are created only when this exact API/environment binding is supplied."
  validation {
    condition = var.authorizer_handoff == null || (
      can(regex("^[a-z0-9]+$", var.authorizer_handoff.api_id)) &&
      var.authorizer_handoff.execution_arn == "arn:aws:execute-api:${var.aws_region}:${var.account_id}:${var.authorizer_handoff.api_id}" &&
      can(regex("^[A-Za-z0-9]+$", var.authorizer_handoff.authorizer_id)) &&
      var.authorizer_handoff.environment == var.environment
    )
    error_message = "authorizer_handoff must contain the reviewed same-account API ID, execution ARN, authorizer ID and environment."
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
