mock_provider "aws" {}

variables {
  name             = "oficina-phase3"
  environment      = "staging"
  aws_region       = "us-east-1"
  legacy_test_mode = true
  network = {
    private_subnet_ids         = ["subnet-0123456789abcdef0", "subnet-abcdef0123456789"]
    function_security_group_id = "sg-0123456789abcdef0"
  }
  lambda_artifact = {
    s3_bucket         = "oficina-artifacts-123456789012"
    s3_key            = "functions/staging/oficina-functions.jar"
    s3_object_version = "3HL4kqtJlcpXroDTDmjVBH40Nrjfkd"
    sha256_base64     = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    sha256_hex        = "0000000000000000000000000000000000000000000000000000000000000000"
  }
  runtime_secret_arns = {
    auth_lookup          = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/auth-lookup-AAAAAA"
    notification_lookup  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/notification-lookup-BBBBBB"
    customer_signing_key = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/customer-signing-CCCCCC"
    authorizer_trust     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/authorizer-trust-DDDDDD"
    rds_ca_certificate   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/rds-ca-EEEEEE"
  }
  customer_key_id             = "customer-2026-01"
  staff_key_id                = "staff-2026-01"
  ses_sender_email            = "no-reply@example.invalid"
  ses_sandbox_mode            = true
  approved_secret_count       = 16
  planned_monthly_invocations = { challenge = 100, verification = 100, authorizer = 1000, notification = 100 }
  newrelic_function_instrumentation = {
    for key in ["challenge", "verification", "authorizer", "notification"] : key => {
      function_name                      = "oficina-phase3-staging-${key}"
      layers                             = ["arn:aws:lambda:us-east-1:451483290750:layer:NewRelicJava17:42", "arn:aws:lambda:us-east-1:451483290750:layer:NewRelicExtension:18"]
      environment                        = { NEW_RELIC_LAMBDA_EXTENSION_ENABLED = "true", NEW_RELIC_LAMBDA_EXTENSION_LOGS_ENABLED = "true", NEW_RELIC_APPLICATION_LOGGING_FORWARDING_ENABLED = "false", NEW_RELIC_LICENSE_KEY_SECRET = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-AbCdEf" }
      log_forwarder                      = "newrelic-extension"
      cloudwatch_subscription_filter_arn = ""
    }
  }
  newrelic_extension_secret_access_policy_json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\"],\"Resource\":[\"arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-AbCdEf\"]}]}"
}

override_resource {
  target = aws_iam_role.function["challenge"]
  values = { arn = "arn:aws:iam::123456789012:role/oficina-staging-challenge" }
}
override_resource {
  target = aws_iam_role.function["verification"]
  values = { arn = "arn:aws:iam::123456789012:role/oficina-staging-verification" }
}
override_resource {
  target = aws_iam_role.function["authorizer"]
  values = { arn = "arn:aws:iam::123456789012:role/oficina-staging-authorizer" }
}
override_resource {
  target = aws_iam_role.function["notification"]
  values = { arn = "arn:aws:iam::123456789012:role/oficina-staging-notification" }
}

run "mock_plan_requires_reviewed_inputs" {
  command = plan
  assert {
    condition     = var.approved_secret_count == 16 && var.ses_sandbox_mode && var.lambda_artifact.sha256_hex != "" && local.planned_monthly_gb_seconds <= 200000
    error_message = "A mocked plan must still require the reviewed secret inventory, sandbox setting and immutable artifact digest."
  }
}

run "fifo_delivery_is_encrypted_and_bounded" {
  command = apply
  assert {
    condition = (
      aws_sqs_queue.notifications.fifo_queue && aws_sqs_queue.notification_dlq.fifo_queue &&
      aws_sqs_queue.notifications.kms_master_key_id == "alias/aws/sqs" && aws_sqs_queue.notification_dlq.kms_master_key_id == "alias/aws/sqs" &&
      aws_sqs_queue.notifications.message_retention_seconds == 345600 && aws_sqs_queue.notification_dlq.message_retention_seconds == 1209600 &&
      aws_sqs_queue.notifications.visibility_timeout_seconds == 120 && jsondecode(aws_sqs_queue.notifications.redrive_policy).maxReceiveCount == 5
    )
    error_message = "The notification FIFO and DLQ require encryption, 4/14-day retention, 120-second visibility and five receives."
  }
  assert {
    condition = (
      aws_lambda_event_source_mapping.notification.batch_size == 1 &&
      aws_lambda_event_source_mapping.notification.scaling_config[0].maximum_concurrency == 2 &&
      aws_lambda_function.function["notification"].memory_size == 1024 && aws_lambda_function.function["notification"].timeout == 20
    )
    error_message = "The FIFO worker must consume one message at a time with bounded concurrency and 1 GiB/20-second runtime."
  }
}

run "all_functions_have_short_logs_tracing_and_pinned_jar" {
  command = apply
  assert {
    condition = (
      alltrue([for function in values(aws_lambda_function.function) :
        function.runtime == "java17" && function.memory_size == 1024 && function.timeout == 20 &&
        function.tracing_config[0].mode == "Active" && function.s3_object_version == var.lambda_artifact.s3_object_version &&
        function.source_code_hash == var.lambda_artifact.sha256_base64
      ]) && alltrue([for log_group in values(aws_cloudwatch_log_group.function) : log_group.retention_in_days == 1])
    )
    error_message = "All handlers must use the immutable Java 17 artifact, bounded runtime, active tracing and one-day logs."
  }
  assert {
    condition = (
      length(aws_lambda_function.function) == 4 &&
      aws_lambda_function.function["challenge"].handler == "com.oficina.functions.handler.CriarDesafioHandler::handleRequest" &&
      aws_lambda_function.function["verification"].handler == "com.oficina.functions.handler.VerificarDesafioHandler::handleRequest" &&
      aws_lambda_function.function["authorizer"].handler == "com.oficina.functions.handler.AuthorizerHandler::handleRequest" &&
      aws_lambda_function.function["notification"].handler == "com.oficina.functions.handler.NotificacaoHandler::handleRequest"
    )
    error_message = "The one shaded JAR must expose all four reviewed handler entry points."
  }
}

run "functions_consume_fun_owned_newrelic_delivery_contract" {
  command = apply
  assert {
    condition     = alltrue([for key, function in aws_lambda_function.function : function.layers == var.newrelic_function_instrumentation[key].layers && function.environment[0].variables.OFICINA_ENVIRONMENT == var.environment && function.environment[0].variables.NEW_RELIC_LAMBDA_EXTENSION_ENABLED == "true" && function.environment[0].variables.NEW_RELIC_LAMBDA_EXTENSION_LOGS_ENABLED == "true" && function.environment[0].variables.NEW_RELIC_APPLICATION_LOGGING_FORWARDING_ENABLED == "false" && function.environment[0].variables.NEW_RELIC_LICENSE_KEY_SECRET == var.newrelic_function_instrumentation[key].environment.NEW_RELIC_LICENSE_KEY_SECRET]) && alltrue([for policy in values(aws_iam_role_policy.function) : strcontains(policy.policy, "newrelic-ingest-AbCdEf") && strcontains(policy.policy, "secretsmanager:GetSecretValue")])
    error_message = "Every deployed Lambda must consume FUN's immutable layers, extension-only log delivery and exact secret-read policy."
  }
}

run "authorizer_is_verification_only" {
  command = apply
  assert {
    condition = (
      !strcontains(aws_iam_role_policy.function["authorizer"].policy, "dynamodb:") &&
      !strcontains(aws_iam_role_policy.function["authorizer"].policy, "ses:SendEmail") &&
      !strcontains(aws_iam_role_policy.function["authorizer"].policy, var.runtime_secret_arns.customer_signing_key) &&
      !contains(keys(aws_lambda_function.function["authorizer"].environment[0].variables), "CUSTOMER_SIGNING_SECRET_ARN")
    )
    error_message = "The authorizer may verify tokens only; it cannot mutate state, send email or receive customer signing material."
  }
}

run "handler_secret_arns_match_the_fun_resolver_contract" {
  command = apply
  assert {
    condition = (
      aws_lambda_function.function["challenge"].environment[0].variables["DATABASE_SECRET_ARN"] == var.runtime_secret_arns.auth_lookup &&
      aws_lambda_function.function["challenge"].environment[0].variables["RDS_CA_CERT_SECRET_ARN"] == var.runtime_secret_arns.rds_ca_certificate &&
      !contains(keys(aws_lambda_function.function["challenge"].environment[0].variables), "CUSTOMER_SIGNING_SECRET_ARN") &&
      aws_lambda_function.function["verification"].environment[0].variables["DATABASE_SECRET_ARN"] == var.runtime_secret_arns.auth_lookup &&
      aws_lambda_function.function["verification"].environment[0].variables["CUSTOMER_SIGNING_SECRET_ARN"] == var.runtime_secret_arns.customer_signing_key &&
      aws_lambda_function.function["authorizer"].environment[0].variables["AUTHORIZER_TRUST_SECRET_ARN"] == var.runtime_secret_arns.authorizer_trust &&
      !contains(keys(aws_lambda_function.function["authorizer"].environment[0].variables), "DATABASE_SECRET_ARN") &&
      aws_lambda_function.function["notification"].environment[0].variables["DATABASE_SECRET_ARN"] == var.runtime_secret_arns.notification_lookup &&
      aws_lambda_function.function["notification"].environment[0].variables["RDS_CA_CERT_SECRET_ARN"] == var.runtime_secret_arns.rds_ca_certificate
    )
    error_message = "Each Lambda must receive only the SecretResolver ARN settings declared for its handler."
  }
}

run "runtime_permissions_are_ledger_and_queue_scoped" {
  command = apply
  assert {
    condition = (
      strcontains(aws_iam_role_policy.function["notification"].policy, "sqs:DeleteMessage") &&
      strcontains(aws_iam_role_policy.function["notification"].policy, aws_sqs_queue.notifications.arn) &&
      strcontains(aws_iam_role_policy.function["notification"].policy, "dynamodb:UpdateItem") &&
      strcontains(aws_iam_role_policy.function["notification"].policy, aws_dynamodb_table.delivery.arn) &&
      jsondecode(aws_iam_policy.notification_publisher.policy).Statement[0].Action == ["sqs:SendMessage"] &&
      jsondecode(aws_iam_policy.notification_publisher.policy).Statement[0].Resource == aws_sqs_queue.notifications.arn
    )
    error_message = "Notification consumes only its source queue, updates only its ledger and the publisher can only send to this FIFO queue."
  }
}

run "secret_budget_is_a_deployment_precondition" {
  command = apply
  assert {
    condition     = var.approved_secret_count == 16 && length(values(var.runtime_secret_arns)) == 5
    error_message = "I5 must use existing named secrets without exceeding the approved inventory."
  }
}
