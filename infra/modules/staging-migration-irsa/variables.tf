variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Exact reviewed AWS account ID required."
  }
}
variable "aws_region" {
  type = string
  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "Migration identity is staging/us-east-1 only."
  }
}
variable "oidc_issuer" { type = string }
variable "oidc_provider_arn" {
  type = string
  validation {
    condition     = can(regex("^https://oidc\\.eks\\.us-east-1\\.amazonaws\\.com/id/[A-Fa-f0-9]{32}$", var.oidc_issuer)) && var.oidc_provider_arn == "arn:aws:iam::${var.account_id}:oidc-provider/${trimprefix(var.oidc_issuer, "https://")}"
    error_message = "Exact same-account foundation OIDC provider required."
  }
}
variable "role_name" {
  type = string
  validation {
    condition     = var.role_name == "oficina-phase3-staging-migration"
    error_message = "Only the reviewed distinct staging migration role name is permitted."
  }
}
variable "source_commit" {
  type = string
  validation {
    condition     = can(regex("^[a-f0-9]{40}$", var.source_commit))
    error_message = "APP source commit must be reviewed."
  }
}
variable "bootstrap_review_sha256" {
  type = string
  validation {
    condition     = can(regex("^[a-f0-9]{64}$", var.bootstrap_review_sha256))
    error_message = "Exact APP bootstrap review bytes must be hash-bound."
  }
}
variable "secret_refs" {
  type = map(object({
    arn             = string
    version_id      = string
    kms_key_manager = string
    kms_key_arn     = optional(string)
    metadata_sha256 = string
  }))
  validation {
    condition = toset(keys(var.secret_refs)) == toset(["master", "migration", "app", "auth", "notification"]) && alltrue([for slot, ref in var.secret_refs :
      can(regex(slot == "master" ? "^arn:aws:secretsmanager:us-east-1:${var.account_id}:secret:rds!db-[A-Za-z0-9-]+$" : "^arn:aws:secretsmanager:us-east-1:${var.account_id}:secret:oficina/staging/${slot}-[A-Za-z0-9]{6}$", ref.arn)) &&
      can(regex("^[A-Za-z0-9-]{32,64}$", ref.version_id)) && can(regex("^[a-f0-9]{64}$", ref.metadata_sha256)) &&
      (ref.kms_key_manager == "AWS" ? ref.kms_key_arn == null : ref.kms_key_manager == "CUSTOMER" && can(regex("^arn:aws:kms:us-east-1:${var.account_id}:key/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", ref.kms_key_arn)))
    ])
    error_message = "Exactly five immutable bootstrap references and explicit reviewed KMS metadata required; no wildcard, production, missing key, alias or foreign account."
  }
}
