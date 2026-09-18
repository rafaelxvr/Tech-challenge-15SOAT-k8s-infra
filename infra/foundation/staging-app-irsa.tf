# Foundation owns the cluster OIDC provider and runtime IAM. Environment
# executors receive no new IAM permissions. Null preserves existing resources.
variable "staging_app_irsa" {
  type = object({
    runtime_secret_arns            = object({ app = string, authorizer_trust = string, newrelic_ingest = string })
    notification_queue_arn         = string
    secret_kms_key_arns            = optional(map(string), {})
    notification_queue_kms_key_arn = optional(string)
  })
  default     = null
  description = "Optional reviewed staging runtime references; this creates no secrets, queue, keys or production role."
}

module "staging_app_irsa" {
  for_each                       = var.staging_app_irsa == null ? {} : { staging = var.staging_app_irsa }
  source                         = "../modules/staging-app-irsa"
  account_id                     = var.account_id
  aws_region                     = var.aws_region
  oidc_provider_arn              = module.cluster.cluster_oidc_provider_arn
  oidc_issuer                    = module.cluster.cluster_oidc_issuer
  runtime_secret_arns            = each.value.runtime_secret_arns
  notification_queue_arn         = each.value.notification_queue_arn
  secret_kms_key_arns            = each.value.secret_kms_key_arns
  notification_queue_kms_key_arn = each.value.notification_queue_kms_key_arn
}

output "staging_app_irsa_role_arn" {
  value       = try(module.staging_app_irsa["staging"].role_arn, null)
  description = "Nonsecret reviewed role ARN for the APP staging platform input; null until explicitly configured."
}
