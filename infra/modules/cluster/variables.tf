variable "name" { type = string }
variable "aws_region" { type = string }
variable "vpc_id" { type = string }
variable "private_subnets_by_az" { type = map(string) }
variable "cluster_role_arn" { type = string }
variable "node_role_arn" { type = string }
variable "oidc_thumbprint" {
  type        = string
  description = "Verified SHA-1 thumbprint for the EKS issuer certificate chain, supplied at reviewed apply time."
  validation {
    condition     = can(regex("^[A-Fa-f0-9]{40}$", var.oidc_thumbprint))
    error_message = "oidc_thumbprint must be a verified 40-character SHA-1 thumbprint."
  }
}
variable "node_ami_release_version" {
  type        = string
  description = "Reviewed, EKS 1.35-compatible AL2023 release version. It is deliberately required rather than guessed."
  validation {
    condition     = can(regex("^1\\.35\\..+", var.node_ami_release_version))
    error_message = "node_ami_release_version must be a verified EKS 1.35 AL2023 release version."
  }
}
variable "vpc_cni_addon_version" {
  type        = string
  description = "Reviewed compatible vpc-cni add-on version with network-policy support."
  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", var.vpc_cni_addon_version))
    error_message = "vpc_cni_addon_version must be an explicit EKS build version."
  }
}
variable "coredns_addon_version" {
  type        = string
  description = "Reviewed compatible CoreDNS add-on version."
  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", var.coredns_addon_version))
    error_message = "coredns_addon_version must be an explicit EKS build version."
  }
}
