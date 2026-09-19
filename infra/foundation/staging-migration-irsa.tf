# Absent by default. This optional module never broadens the APP runtime role.
variable "staging_migration_irsa" {
  type = object({
    role_name               = string
    source_commit           = string
    bootstrap_review_sha256 = string
    secret_refs = map(object({
      arn         = string, version_id = string, kms_key_manager = string,
      kms_key_arn = optional(string), metadata_sha256 = string
    }))
  })
  default     = null
  description = "Explicit reviewed staging bootstrap identity and nonsecret metadata. Null creates nothing; there is no production path."
}
module "staging_migration_irsa" {
  for_each                = var.staging_migration_irsa == null ? {} : { staging = var.staging_migration_irsa }
  source                  = "../modules/staging-migration-irsa"
  account_id              = var.account_id
  aws_region              = var.aws_region
  oidc_provider_arn       = module.cluster.cluster_oidc_provider_arn
  oidc_issuer             = module.cluster.cluster_oidc_issuer
  role_name               = each.value.role_name
  source_commit           = each.value.source_commit
  bootstrap_review_sha256 = each.value.bootstrap_review_sha256
  secret_refs             = each.value.secret_refs
}
output "staging_migration_identity_json" { value = try(module.staging_migration_irsa["staging"].identity_json, null) }
output "staging_migration_identity_sha256" { value = try(module.staging_migration_irsa["staging"].identity_sha256, null) }
