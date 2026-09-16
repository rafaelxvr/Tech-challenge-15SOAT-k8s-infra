variable "aws_region" { type = string }
variable "name" { type = string }
variable "foundation_outputs" { type = object({ private_subnet_ids = set(string), function_security_group_id = string }) }
variable "lambda_artifact" { type = object({ s3_bucket = string, s3_key = string, s3_object_version = string, sha256_base64 = string, sha256_hex = string }) }
variable "runtime_secret_arns" { type = object({ auth_lookup = string, notification_lookup = string, customer_signing_key = string, authorizer_trust = string, rds_ca_certificate = string }) }
variable "customer_key_id" { type = string }
variable "staff_key_id" { type = string }
variable "ses_sender_email" { type = string }
variable "ses_sandbox_mode" { type = bool }
variable "approved_secret_count" { type = number }
variable "planned_monthly_invocations" { type = object({ challenge = number, verification = number, authorizer = number, notification = number }) }
