variable "aws_region" { type = string }
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
  description = "The allowlisted foundation outputs.v1.json values, injected by the verified deployment workflow."
}
