locals {
  oidc_host = trimprefix(var.oidc_issuer, "https://")
  trust = jsonencode({
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
  })
  runtime_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "ReadOnlyStagingAppRuntimeSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = sort(values(var.runtime_secret_arns))
      },
      {
        Sid      = "PublishOnlyStagingNotifications"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [var.notification_queue_arn]
      }
      ], [for slot, key_arn in var.secret_kms_key_arns : {
        Sid      = "DecryptRuntimeSecret${replace(slot, "_", "")}"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [key_arn]
        Condition = { StringEquals = {
          "kms:CallerAccount"               = var.account_id
          "kms:ViaService"                  = "secretsmanager.${var.aws_region}.amazonaws.com"
          "kms:EncryptionContext:SecretARN" = lookup(var.runtime_secret_arns, slot, "")
        } }
        }], var.notification_queue_kms_key_arn == null ? [] : [{
        Sid      = "EncryptOnlyStagingQueueMessages"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [var.notification_queue_kms_key_arn]
        Condition = { StringEquals = {
          "kms:CallerAccount"                 = var.account_id
          "kms:ViaService"                    = "sqs.${var.aws_region}.amazonaws.com"
          "kms:EncryptionContext:aws:sqs:arn" = var.notification_queue_arn
        } }
    }])
  })
}

resource "aws_iam_role" "app" {
  name               = "oficina-phase3-staging-app"
  assume_role_policy = local.trust
  tags               = { project = "oficina-phase3", environment = "staging", managedBy = "oficina-k8s-infra", component = "application" }
}
resource "aws_iam_role_policy" "runtime" {
  name   = "staging-runtime-only"
  role   = aws_iam_role.app.id
  policy = local.runtime_policy
}
