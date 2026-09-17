variable "aws_region" {
  type = string
  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "Foundation addons are approved only in us-east-1."
  }
}
variable "cluster_name" { type = string }
variable "cluster_endpoint" {
  type = string
  validation {
    condition     = can(regex("^https://", var.cluster_endpoint))
    error_message = "cluster_endpoint must be private HTTPS."
  }
}
variable "cluster_ca_certificate" {
  type      = string
  sensitive = true
}
variable "vpc_id" { type = string }
variable "load_balancer_controller_role_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.load_balancer_controller_role_arn))
    error_message = "Use the reviewed foundation controller role."
  }
}
