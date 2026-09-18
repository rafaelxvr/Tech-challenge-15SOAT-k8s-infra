mock_provider "aws" {}
variables {
  account_id        = "123456789012"
  aws_region        = "us-east-1"
  oidc_issuer       = "https://oidc.eks.us-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF"
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF"
  runtime_secret_arns = {
    app              = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/app-AbCd12"
    authorizer_trust = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/authorizer-trust-EfGh34"
    newrelic_ingest  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-IjKl56"
  }
  notification_queue_arn = "arn:aws:sqs:us-east-1:123456789012:oficina-phase3-staging-notifications.fifo"
}
run "exact_staging_trust_and_permissions" {
  command = plan
  assert {
    condition = jsondecode(aws_iam_role.app.assume_role_policy) == {
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Action    = "sts:AssumeRoleWithWebIdentity"
        Principal = { Federated = var.oidc_provider_arn }
        Condition = { StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = "system:serviceaccount:oficina-staging:oficina-app"
        } }
      }]
    }
    error_message = "Trust must bind one exact provider, audience and staging service account."
  }
  assert {
    condition     = aws_iam_role.app.name == "oficina-phase3-staging-app" && aws_iam_role.app.tags.environment == "staging"
    error_message = "Role identity must remain staging-only."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.runtime.policy).Statement) == 2 && toset(jsondecode(local.runtime_policy).Statement[0].Action) == toset(["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]) && toset(jsondecode(local.runtime_policy).Statement[0].Resource) == toset(values(var.runtime_secret_arns)) && jsondecode(local.runtime_policy).Statement[1].Action == ["sqs:SendMessage"] && jsondecode(local.runtime_policy).Statement[1].Resource == [var.notification_queue_arn]
    error_message = "Default policy must contain only three runtime secrets and one queue publish grant, with no KMS or wildcard access."
  }
}
run "customer_keys_are_exact_and_service_scoped" {
  command = plan
  variables {
    secret_kms_key_arns = {
      app              = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
      authorizer_trust = "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"
      newrelic_ingest  = "arn:aws:kms:us-east-1:123456789012:key/33333333-3333-3333-3333-333333333333"
    }
    notification_queue_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/44444444-4444-4444-4444-444444444444"
  }
  assert {
    condition = length(jsondecode(local.runtime_policy).Statement) == 6 && alltrue([for index, slot in sort(keys(var.secret_kms_key_arns)) : jsondecode(local.runtime_policy).Statement[index + 2].Action == ["kms:Decrypt"] && jsondecode(local.runtime_policy).Statement[index + 2].Resource == [var.secret_kms_key_arns[slot]] && jsondecode(local.runtime_policy).Statement[index + 2].Condition.StringEquals == {
      "kms:CallerAccount"               = var.account_id
      "kms:ViaService"                  = "secretsmanager.us-east-1.amazonaws.com"
      "kms:EncryptionContext:SecretARN" = var.runtime_secret_arns[slot]
    }])
    error_message = "Each secret KMS grant must decrypt only its exact key and secret through Secrets Manager in the same account."
  }
  assert {
    condition = toset(jsondecode(local.runtime_policy).Statement[5].Action) == toset(["kms:Decrypt", "kms:GenerateDataKey"]) && jsondecode(local.runtime_policy).Statement[5].Resource == [var.notification_queue_kms_key_arn] && jsondecode(local.runtime_policy).Statement[5].Condition.StringEquals == {
      "kms:CallerAccount"                 = var.account_id
      "kms:ViaService"                    = "sqs.us-east-1.amazonaws.com"
      "kms:EncryptionContext:aws:sqs:arn" = var.notification_queue_arn
    }
    error_message = "Queue KMS grant must bind the exact key, queue context, caller account and SQS service."
  }
}
run "reject_secret_production" {
  command = plan
  variables {
    runtime_secret_arns = {
      app              = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/production/app-AbCd12"
      authorizer_trust = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/authorizer-trust-EfGh34"
      newrelic_ingest  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-IjKl56"
    }
  }
  expect_failures = [var.runtime_secret_arns]
}
run "reject_secret_foreign" {
  command = plan
  variables {
    runtime_secret_arns = {
      app              = "arn:aws:secretsmanager:us-east-1:999999999999:secret:oficina/staging/app-AbCd12"
      authorizer_trust = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/authorizer-trust-EfGh34"
      newrelic_ingest  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-IjKl56"
    }
  }
  expect_failures = [var.runtime_secret_arns]
}
run "reject_secret_signing" {
  command = plan
  variables {
    runtime_secret_arns = {
      app              = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/customer-signing-AbCd12"
      authorizer_trust = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/authorizer-trust-EfGh34"
      newrelic_ingest  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-IjKl56"
    }
  }
  expect_failures = [var.runtime_secret_arns]
}
run "reject_secret_wildcard" {
  command = plan
  variables {
    runtime_secret_arns = {
      app              = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/app-*"
      authorizer_trust = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/authorizer-trust-EfGh34"
      newrelic_ingest  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-IjKl56"
    }
  }
  expect_failures = [var.runtime_secret_arns]
}
run "reject_secret_master" {
  command = plan
  variables {
    runtime_secret_arns = {
      app              = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/master-AbCd12"
      authorizer_trust = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/authorizer-trust-EfGh34"
      newrelic_ingest  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-IjKl56"
    }
  }
  expect_failures = [var.runtime_secret_arns]
}
run "reject_secret_migration" {
  command = plan
  variables {
    runtime_secret_arns = {
      app              = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/migration-AbCd12"
      authorizer_trust = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/authorizer-trust-EfGh34"
      newrelic_ingest  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-IjKl56"
    }
  }
  expect_failures = [var.runtime_secret_arns]
}
run "reject_provider_account" {
  command = plan
  variables {
    oidc_provider_arn = "arn:aws:iam::999999999999:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF"
  }
  expect_failures = [var.oidc_provider_arn]
}
run "reject_provider_issuer" {
  command = plan
  variables {
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
  }
  expect_failures = [var.oidc_provider_arn]
}
run "reject_queue_production" {
  command = plan
  variables {
    notification_queue_arn = "arn:aws:sqs:us-east-1:123456789012:oficina-phase3-production-notifications.fifo"
  }
  expect_failures = [var.notification_queue_arn]
}
run "reject_queue_foreign" {
  command = plan
  variables {
    notification_queue_arn = "arn:aws:sqs:us-east-1:999999999999:oficina-phase3-staging-notifications.fifo"
  }
  expect_failures = [var.notification_queue_arn]
}
run "reject_queue_dlq" {
  command = plan
  variables {
    notification_queue_arn = "arn:aws:sqs:us-east-1:123456789012:oficina-phase3-staging-notifications-dlq.fifo"
  }
  expect_failures = [var.notification_queue_arn]
}
run "reject_kms_slot" {
  command = plan
  variables {
    secret_kms_key_arns = { master = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111" }
  }
  expect_failures = [var.secret_kms_key_arns]
}
run "reject_kms_wildcard" {
  command = plan
  variables {
    secret_kms_key_arns = { app = "*" }
  }
  expect_failures = [var.secret_kms_key_arns]
}
run "reject_kms_alias" {
  command = plan
  variables {
    secret_kms_key_arns = { app = "arn:aws:kms:us-east-1:123456789012:alias/app" }
  }
  expect_failures = [var.secret_kms_key_arns]
}
run "reject_kms_foreign" {
  command = plan
  variables {
    secret_kms_key_arns = { app = "arn:aws:kms:us-east-1:999999999999:key/11111111-1111-1111-1111-111111111111" }
  }
  expect_failures = [var.secret_kms_key_arns]
}
run "reject_queue_kms_wildcard" {
  command = plan
  variables {
    notification_queue_kms_key_arn = "*"
  }
  expect_failures = [var.notification_queue_kms_key_arn]
}
run "reject_wildcard_issuer" {
  command = plan
  variables {
    oidc_issuer       = "https://oidc.eks.us-east-1.amazonaws.com/id/*"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/*"
  }
  expect_failures = [var.oidc_issuer]
}
run "reject_foreign_issuer_host" {
  command = plan
  variables {
    oidc_issuer       = "https://issuer.example.com/id/0123456789ABCDEF0123456789ABCDEF"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/issuer.example.com/id/0123456789ABCDEF0123456789ABCDEF"
  }
  expect_failures = [var.oidc_issuer]
}
