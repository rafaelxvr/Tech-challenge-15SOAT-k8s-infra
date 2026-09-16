provider "aws" { region = var.aws_region }

module "functions" {
  source                      = "../../modules/functions"
  name                        = var.name
  environment                 = "staging"
  aws_region                  = var.aws_region
  network                     = var.network
  lambda_artifact             = var.lambda_artifact
  runtime_secret_arns         = var.runtime_secret_arns
  customer_key_id             = var.customer_key_id
  staff_key_id                = var.staff_key_id
  database                    = var.database
  ses_sender_email            = var.ses_sender_email
  ses_sandbox_mode            = var.ses_sandbox_mode
  approved_secret_count       = var.approved_secret_count
  planned_monthly_invocations = var.planned_monthly_invocations
}
