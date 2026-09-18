variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Use the reviewed 12-digit foundation account."
  }
}
variable "aws_region" {
  type = string
  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "Staging APP IRSA is approved only in us-east-1."
  }
}
variable "oidc_issuer" {
  type = string
  validation {
    condition     = can(regex("^https://oidc\\.eks\\.us-east-1\\.amazonaws\\.com/id/[A-Fa-f0-9]{32}$", var.oidc_issuer))
    error_message = "Use the exact foundation EKS OIDC issuer without wildcards or trailing slash."
  }
}
variable "oidc_provider_arn" {
  type = string
  validation {
    condition     = var.oidc_provider_arn == "arn:aws:iam::${var.account_id}:oidc-provider/${trimprefix(var.oidc_issuer, "https://")}"
    error_message = "The OIDC provider must match the foundation issuer and account exactly."
  }
}
variable "runtime_secret_arns" {
  type = object({ app = string, authorizer_trust = string, newrelic_ingest = string })
  validation {
    condition = alltrue([for name, arn in var.runtime_secret_arns :
      can(regex("^arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:oficina/staging/${replace(name, "_", "-")}-[A-Za-z0-9]{6}$", arn))
    ])
    error_message = "Only exact same-account staging app, authorizer-trust and newrelic-ingest secret ARNs are allowed."
  }
}
variable "notification_queue_arn" {
  type = string
  validation {
    condition     = var.notification_queue_arn == "arn:aws:sqs:${var.aws_region}:${var.account_id}:oficina-phase3-staging-notifications.fifo"
    error_message = "APP may publish only to the exact same-account staging notification FIFO queue."
  }
}
variable "secret_kms_key_arns" {
  type        = map(string)
  default     = {}
  description = "Optional exact customer-managed keys by runtime-secret slot; no key discovery or key-policy changes."
  validation {
    condition = alltrue([for slot, arn in var.secret_kms_key_arns :
      contains(keys(var.runtime_secret_arns), slot) &&
      can(regex("^arn:aws:kms:${var.aws_region}:${var.account_id}:key/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", arn))
    ])
    error_message = "KMS mappings must use only the three runtime-secret slots and exact same-account us-east-1 key ARNs."
  }
}
variable "notification_queue_kms_key_arn" {
  type        = string
  default     = null
  description = "Optional exact reviewed queue KMS key ARN; omit only when no explicit identity-policy KMS grant is required."
  validation {
    condition     = var.notification_queue_kms_key_arn == null || can(regex("^arn:aws:kms:${var.aws_region}:${var.account_id}:key/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", var.notification_queue_kms_key_arn))
    error_message = "The notification key must be an exact same-account us-east-1 KMS key ARN, never an alias or wildcard."
  }
}
