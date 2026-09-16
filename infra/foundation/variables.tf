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
variable "platform_binding_principal_arn" {
  type        = string
  description = "Dedicated reviewed IAM role used only by the trusted platform binding step; it is never an application release role."
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.platform_binding_principal_arn))
    error_message = "platform_binding_principal_arn must be the reviewed dedicated IAM role ARN."
  }
}
variable "deployments" {
  type = map(object({
    repository    = string
    environment   = string
    source_prefix = string
  }))
}
