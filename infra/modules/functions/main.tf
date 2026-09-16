locals {
  prefix = "${var.name}-${var.environment}"
  tags = {
    project     = "oficina-phase3"
    environment = var.environment
    managedBy   = "oficina-k8s-infra"
    component   = "functions"
  }
  customer_issuer            = "oficina-${var.environment}-customer"
  staff_issuer               = "oficina-${var.environment}-staff"
  audience                   = "oficina-${var.environment}-api"
  planned_monthly_gb_seconds = sum([for count in values(var.planned_monthly_invocations) : count * 20])
  function_handlers = {
    challenge    = "com.oficina.functions.handler.CriarDesafioHandler::handleRequest"
    verification = "com.oficina.functions.handler.VerificarDesafioHandler::handleRequest"
    authorizer   = "com.oficina.functions.handler.AuthorizerHandler::handleRequest"
    notification = "com.oficina.functions.handler.NotificacaoHandler::handleRequest"
  }
  lambda_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  log_group_names = {
    for function_name in keys(local.function_handlers) : function_name => "/aws/lambda/${local.prefix}-${function_name}"
  }
  lambda_logs_statement = {
    Effect   = "Allow"
    Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    Resource = [for name in values(local.log_group_names) : "arn:aws:logs:${var.aws_region}:*:log-group:${name}:*"]
  }
  vpc_statement = {
    Effect = "Allow"
    Action = [
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses"
    ]
    Resource = "*"
  }
  tracing_statement = {
    Effect   = "Allow"
    Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    Resource = "*"
  }
  role_statements = {
    authorizer = [
      {
        Sid      = "ReadAuthorizerTrustOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.runtime_secret_arns.authorizer_trust]
      }
    ]
    challenge = [
      {
        Sid      = "ChallengeStateOnly"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:TransactWriteItems"]
        Resource = [aws_dynamodb_table.challenge.arn]
      },
      {
        Sid      = "ReadChallengeDatabaseAndCaOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.runtime_secret_arns.auth_lookup, var.runtime_secret_arns.rds_ca_certificate]
      },
      {
        Sid       = "SendOtpFromVerifiedSender"
        Effect    = "Allow"
        Action    = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource  = "*"
        Condition = { StringEquals = { "ses:FromAddress" = var.ses_sender_email } }
      }
    ]
    verification = [
      {
        Sid      = "ChallengeStateOnly"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:TransactWriteItems"]
        Resource = [aws_dynamodb_table.challenge.arn]
      },
      {
        Sid      = "ReadVerificationDatabaseAndCaOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.runtime_secret_arns.auth_lookup, var.runtime_secret_arns.rds_ca_certificate]
      },
      {
        Sid      = "ReadCustomerSigningKeyOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.runtime_secret_arns.customer_signing_key]
      }
    ]
    notification = [
      {
        Sid      = "ConsumeThisQueueOnly"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource = [aws_sqs_queue.notifications.arn]
      },
      {
        Sid      = "DeliveryLedgerOnly"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:TransactWriteItems"]
        Resource = [aws_dynamodb_table.delivery.arn]
      },
      {
        Sid      = "ReadNotificationDatabaseAndCaOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.runtime_secret_arns.notification_lookup, var.runtime_secret_arns.rds_ca_certificate]
      },
      {
        Sid       = "SendStatusFromVerifiedSender"
        Effect    = "Allow"
        Action    = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource  = "*"
        Condition = { StringEquals = { "ses:FromAddress" = var.ses_sender_email } }
      }
    ]
  }
}

resource "aws_sqs_queue" "notification_dlq" {
  name                        = "${local.prefix}-notifications-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  deduplication_scope         = "messageGroup"
  fifo_throughput_limit       = "perMessageGroupId"
  message_retention_seconds   = 1209600
  kms_master_key_id           = "alias/aws/sqs"
  tags                        = local.tags
}

resource "aws_sqs_queue" "notifications" {
  name                        = "${local.prefix}-notifications.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  deduplication_scope         = "messageGroup"
  fifo_throughput_limit       = "perMessageGroupId"
  message_retention_seconds   = 345600
  visibility_timeout_seconds  = 120
  receive_wait_time_seconds   = 20
  kms_master_key_id           = "alias/aws/sqs"
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notification_dlq.arn
    maxReceiveCount     = 5
  })
  tags = local.tags
}

resource "aws_dynamodb_table" "challenge" {
  name         = "${local.prefix}-auth-challenges"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  attribute {
    name = "PK"
    type = "S"
  }
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
  server_side_encryption { enabled = true }
  point_in_time_recovery { enabled = true }
  tags = local.tags
}

resource "aws_dynamodb_table" "delivery" {
  name         = "${local.prefix}-notification-delivery"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  attribute {
    name = "PK"
    type = "S"
  }
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
  server_side_encryption { enabled = true }
  point_in_time_recovery { enabled = true }
  tags = local.tags
}

resource "aws_cloudwatch_log_group" "function" {
  for_each          = local.log_group_names
  name              = each.value
  retention_in_days = 1
  tags              = local.tags
}

resource "aws_iam_role" "function" {
  for_each           = local.function_handlers
  name               = "${local.prefix}-${each.key}"
  assume_role_policy = local.lambda_assume_role_policy
  tags               = local.tags
}

resource "aws_iam_role_policy" "function" {
  for_each = local.function_handlers
  name     = "${local.prefix}-${each.key}-runtime"
  role     = aws_iam_role.function[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [local.lambda_logs_statement, local.vpc_statement, local.tracing_statement],
      local.role_statements[each.key]
    )
  })
}

resource "aws_iam_policy" "notification_publisher" {
  name        = "${local.prefix}-notification-publisher"
  description = "Attach only to the APP environment runtime role; it publishes status events to this environment's FIFO queue."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "PublishToThisEnvironmentOnly"
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.notifications.arn
    }]
  })
  tags = local.tags
}

resource "aws_lambda_function" "function" {
  for_each          = local.function_handlers
  function_name     = "${local.prefix}-${each.key}"
  role              = aws_iam_role.function[each.key].arn
  handler           = each.value
  runtime           = "java17"
  architectures     = ["x86_64"]
  s3_bucket         = var.lambda_artifact.s3_bucket
  s3_key            = var.lambda_artifact.s3_key
  s3_object_version = var.lambda_artifact.s3_object_version
  source_code_hash  = var.lambda_artifact.sha256_base64
  memory_size       = 1024
  timeout           = 20
  publish           = false

  vpc_config {
    subnet_ids         = tolist(var.network.private_subnet_ids)
    security_group_ids = [var.network.function_security_group_id]
  }

  tracing_config { mode = "Active" }

  environment {
    variables = merge({
      LOG_FORMAT                  = "JSON"
      LOG_LEVEL                   = "INFO"
      METRICS_NAMESPACE           = "Oficina/Functions"
      POWERTOOLS_LOGGER_LOG_EVENT = "false"
      }, each.key == "authorizer" ? {
      CUSTOMER_JWT_ISSUER         = local.customer_issuer
      CUSTOMER_JWT_AUDIENCE       = local.audience
      CUSTOMER_KEY_ID             = var.customer_key_id
      STAFF_JWT_ISSUER            = local.staff_issuer
      STAFF_JWT_AUDIENCE          = local.audience
      STAFF_KEY_ID                = var.staff_key_id
      AUTHORIZER_TRUST_SECRET_ARN = var.runtime_secret_arns.authorizer_trust
      } : each.key == "notification" ? {
      DB_CA_PATH             = "/tmp/oficina/rds-ca.pem"
      DELIVERY_TABLE         = aws_dynamodb_table.delivery.name
      DATABASE_SECRET_ARN    = var.runtime_secret_arns.notification_lookup
      RDS_CA_CERT_SECRET_ARN = var.runtime_secret_arns.rds_ca_certificate
      STATUS_SENDER          = var.ses_sender_email
      } : merge({
        DB_CA_PATH             = "/tmp/oficina/rds-ca.pem"
        CHALLENGE_TABLE        = aws_dynamodb_table.challenge.name
        DATABASE_SECRET_ARN    = var.runtime_secret_arns.auth_lookup
        RDS_CA_CERT_SECRET_ARN = var.runtime_secret_arns.rds_ca_certificate
        OTP_SENDER             = var.ses_sender_email
        }, each.key == "verification" ? {
        CUSTOMER_JWT_ISSUER         = local.customer_issuer
        CUSTOMER_JWT_AUDIENCE       = local.audience
        CUSTOMER_KEY_ID             = var.customer_key_id
        CUSTOMER_SIGNING_SECRET_ARN = var.runtime_secret_arns.customer_signing_key
    } : {}))
  }

  depends_on = [aws_cloudwatch_log_group.function]
  tags       = local.tags

  lifecycle {
    precondition {
      condition     = var.approved_secret_count == 16
      error_message = "Function deployment is blocked until the approved 16-secret inventory is reconciled."
    }
    precondition {
      condition     = var.ses_sandbox_mode
      error_message = "Function deployment is limited to the reviewed SES sandbox configuration."
    }
    precondition {
      condition     = local.planned_monthly_gb_seconds <= 200000
      error_message = "The measured four-function runtime forecast exceeds the approved 200,000 GB-second study envelope."
    }
  }
}

resource "aws_lambda_event_source_mapping" "notification" {
  event_source_arn                   = aws_sqs_queue.notifications.arn
  function_name                      = aws_lambda_function.function["notification"].arn
  enabled                            = true
  batch_size                         = 1
  maximum_batching_window_in_seconds = 0
  scaling_config { maximum_concurrency = 2 }
}
