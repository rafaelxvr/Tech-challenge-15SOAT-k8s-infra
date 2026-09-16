output "authorizer_function_arn" {
  value       = aws_lambda_function.function["authorizer"].arn
  description = "The platform state uses this ARN for the one API Gateway REQUEST authorizer binding."
}

output "function_arns" {
  value = {
    authorizer   = aws_lambda_function.function["authorizer"].arn
    challenge    = aws_lambda_function.function["challenge"].arn
    verification = aws_lambda_function.function["verification"].arn
    notification = aws_lambda_function.function["notification"].arn
  }
}

output "authorizer_trust_secret_arn" {
  value       = var.runtime_secret_arns.authorizer_trust
  description = "Authorizer trust secret ARN only; no key or HMAC value is exported."
}

output "notification_queue_url" { value = aws_sqs_queue.notifications.url }
output "notification_queue_arn" { value = aws_sqs_queue.notifications.arn }
output "notification_dlq_arn" { value = aws_sqs_queue.notification_dlq.arn }
output "notification_publisher_policy_arn" { value = aws_iam_policy.notification_publisher.arn }
output "artifact_sha256" { value = var.lambda_artifact.sha256_hex }
output "planned_monthly_gb_seconds" { value = local.planned_monthly_gb_seconds }
