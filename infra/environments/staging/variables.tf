variable "aws_region" { type = string }
variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the reviewed 12-digit deployment account."
  }
}
variable "name" {
  type = string
  validation {
    condition     = var.name == "oficina-phase3"
    error_message = "The reviewed Phase 3 platform name is fixed to oficina-phase3."
  }
}
variable "foundation_outputs" {
  type = object({
    vpc_id                = string
    cluster_name          = string
    vpc_link_id           = string
    backend_listener_arns = map(string)
    codebuild_projects    = map(object({ roleArn = string }))
  })
  description = "The allowlisted foundation outputs.v1.json values resolved from the versioned foundation receipt by the verified deployment workflow."
}
variable "authorizer_handoff" {
  type        = object({ api_id = string, execution_arn = string, authorizer_id = string, environment = string })
  default     = null
  nullable    = true
  description = "Optional reviewed FUN handoff. Omit for the first platform apply; protected routes remain absent until supplied."
  validation {
    condition = var.authorizer_handoff == null || (
      can(regex("^[a-z0-9]+$", var.authorizer_handoff.api_id)) &&
      var.authorizer_handoff.execution_arn == "arn:aws:execute-api:${var.aws_region}:${var.account_id}:${var.authorizer_handoff.api_id}" &&
      can(regex("^[A-Za-z0-9]+$", var.authorizer_handoff.authorizer_id)) &&
      var.authorizer_handoff.environment == "staging"
    )
    error_message = "authorizer_handoff must contain the reviewed same-account API ID, execution ARN, authorizer ID and staging environment."
  }
}
variable "gateway_allowed_origins" {
  type        = set(string)
  description = "Reviewed staging browser origins; required because the platform never opens CORS with a wildcard."
}
