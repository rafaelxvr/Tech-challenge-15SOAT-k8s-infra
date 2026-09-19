locals {
  oidc_host = trimprefix(var.oidc_issuer, "https://")
  trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRoleWithWebIdentity", Principal = { Federated = var.oidc_provider_arn }, Condition = { StringEquals = {
      "${local.oidc_host}:aud" = "sts.amazonaws.com"
      "${local.oidc_host}:sub" = "system:serviceaccount:oficina-staging:oficina-migration-staging"
    } } }]
  })
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([{ Sid = "ReadOnlyReviewedBootstrapSecrets", Effect = "Allow", Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], Resource = sort([for ref in var.secret_refs : ref.arn]), Condition = { StringEquals = { "aws:RequestedRegion" = "us-east-1" } } }],
      [for slot, ref in var.secret_refs : { Sid = "DecryptBootstrap${title(slot)}", Effect = "Allow", Action = ["kms:Decrypt"], Resource = [ref.kms_key_arn], Condition = { StringEquals = {
        "kms:CallerAccount"               = var.account_id
        "kms:ViaService"                  = "secretsmanager.us-east-1.amazonaws.com"
        "kms:EncryptionContext:SecretARN" = ref.arn
    } } } if ref.kms_key_manager == "CUSTOMER"])
  })
}
resource "aws_iam_role" "migration" {
  name               = var.role_name
  assume_role_policy = local.trust
  tags               = { project = "oficina-phase3", environment = "staging", managedBy = "oficina-k8s-infra", component = "migration" }
}
resource "aws_iam_role_policy" "bootstrap" {
  name   = "staging-bootstrap-only"
  role   = aws_iam_role.migration.id
  policy = local.policy
}
locals {
  identity_json = jsonencode({
    schemaVersion    = 1, environment = "staging", sourceCommit = var.source_commit,
    namespace        = "oficina-staging", serviceAccountName = "oficina-migration-staging",
    roleArn          = aws_iam_role.migration.arn, bootstrapReviewSha256 = var.bootstrap_review_sha256,
    oidcProviderArn  = var.oidc_provider_arn, oidcIssuer = var.oidc_issuer,
    secretReferences = { for slot, ref in var.secret_refs : slot => { arn = ref.arn, versionId = ref.version_id, kmsKeyManager = ref.kms_key_manager, kmsKeyArn = ref.kms_key_arn, metadataSha256 = ref.metadata_sha256 } }
  })
}
output "identity_json" { value = local.identity_json }
output "identity_sha256" { value = sha256(local.identity_json) }
output "role_arn" { value = aws_iam_role.migration.arn }
