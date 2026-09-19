mock_provider "aws" {}
variables {
  account_id              = "123456789012"
  aws_region              = "us-east-1"
  role_name               = "oficina-phase3-staging-migration"
  oidc_issuer             = "https://oidc.eks.us-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF"
  oidc_provider_arn       = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF"
  source_commit           = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  bootstrap_review_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  secret_refs = { for slot in ["master", "migration", "app", "auth", "notification"] : slot => {
    arn             = slot == "master" ? "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-test" : "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/${slot}-AbCd12"
    version_id      = "11111111111111111111111111111111"
    kms_key_manager = "AWS"
    metadata_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  } }
}
run "exact_trust_and_five_secret_reads" {
  command = plan
  assert {
    condition = jsondecode(local.trust).Statement == [{ Effect = "Allow", Action = "sts:AssumeRoleWithWebIdentity", Principal = { Federated = var.oidc_provider_arn }, Condition = { StringEquals = {
      "${local.oidc_host}:aud" = "sts.amazonaws.com"
      "${local.oidc_host}:sub" = "system:serviceaccount:oficina-staging:oficina-migration-staging"
    } } }]
    error_message = "Trust must bind exactly one staging migration SA and audience."
  }
  assert {
    condition     = length(jsondecode(local.policy).Statement) == 1 && jsondecode(local.policy).Statement[0].Action == ["secretsmanager:GetSecretValue"] && toset(jsondecode(local.policy).Statement[0].Resource) == toset([for ref in var.secret_refs : ref.arn])
    error_message = "Only five exact secret reads; no runtime queue, write, or KMS wildcard."
  }
}
run "customer_key_requires_exact_context" {
  command = plan
  variables {
    secret_refs = { for slot, ref in var.secret_refs : slot => merge(ref, { kms_key_manager = "CUSTOMER", kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111" }) }
  }
  assert {
    condition = length(jsondecode(local.policy).Statement) == 6 && alltrue([for index, slot in sort(keys(var.secret_refs)) : jsondecode(local.policy).Statement[index + 1].Action == ["kms:Decrypt"] && jsondecode(local.policy).Statement[index + 1].Resource == [var.secret_refs[slot].kms_key_arn] && jsondecode(local.policy).Statement[index + 1].Condition.StringEquals == {
      "kms:CallerAccount"               = var.account_id
      "kms:ViaService"                  = "secretsmanager.us-east-1.amazonaws.com"
      "kms:EncryptionContext:SecretARN" = var.secret_refs[slot].arn
    }])
    error_message = "KMS must bind exact key, secret context, account, and service."
  }
}
run "reject_production_role" {
  command = plan
  variables { role_name = "oficina-phase3-production-migration" }
  expect_failures = [var.role_name]
}
run "reject_missing_secrets" {
  command = plan
  variables { secret_refs = {} }
  expect_failures = [var.secret_refs]
}
run "reject_unresolved_customer_key" {
  command = plan
  variables { secret_refs = { for slot, ref in var.secret_refs : slot => merge(ref, { kms_key_manager = "CUSTOMER" }) } }
  expect_failures = [var.secret_refs]
}
run "reject_foreign_oidc" {
  command = plan
  variables { oidc_provider_arn = "arn:aws:iam::999999999999:oidc-provider/unknown" }
  expect_failures = [var.oidc_provider_arn]
}
run "reject_production_secret" {
  command = plan
  variables { secret_refs = { for slot, ref in var.secret_refs : slot => merge(ref, { arn = replace(ref.arn, "/staging/", "/production/") }) } }
  expect_failures = [var.secret_refs]
}
