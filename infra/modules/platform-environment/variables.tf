variable "name" { type = string }
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
variable "cluster_security_group_id" { type = string }
variable "internal_alb_arn" { type = string }
variable "internal_alb_security_group_id" { type = string }
variable "vpc_link_id" { type = string }
variable "vpc_link_security_group_id" { type = string }
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
