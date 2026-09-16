variable "name" { type = string }
variable "aws_region" { type = string }
variable "account_id" { type = string }
variable "cluster_name" { type = string }
variable "cluster_arn" { type = string }
variable "cluster_endpoint" { type = string }
variable "cluster_ca_certificate" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "security_group_ids" { type = list(string) }
variable "artifact_bucket_name" { type = string }
variable "state_bucket_name" { type = string }
variable "deployer_repository_url" { type = string }
variable "deployer_image_digest" {
  type = string
  validation {
    condition     = can(regex("^sha256:[a-f0-9]{64}$", var.deployer_image_digest))
    error_message = "deployer_image_digest must be an immutable lowercase SHA-256 digest."
  }
}
variable "vpc_id_for_controller" { type = string }
variable "load_balancer_controller_role_arn" { type = string }
