provider "aws" { region = var.aws_region }

module "functions" {
  source      = "../../modules/functions"
  name        = var.name
  environment = "staging"
  aws_region  = var.aws_region
  network = {
    private_subnet_ids         = var.foundation_outputs.private_subnet_ids
    function_security_group_id = var.foundation_outputs.function_security_group_id
  }
  lambda_artifact                              = var.lambda_artifact
  runtime_secret_arns                          = var.runtime_secret_arns
  customer_key_id                              = var.customer_key_id
  staff_key_id                                 = var.staff_key_id
  ses_sender_email                             = var.ses_sender_email
  ses_sandbox_mode                             = var.ses_sandbox_mode
  approved_secret_count                        = var.approved_secret_count
  planned_monthly_invocations                  = var.planned_monthly_invocations
  newrelic_function_instrumentation            = var.newrelic_function_instrumentation
  newrelic_extension_secret_access_policy_json = var.newrelic_extension_secret_access_policy_json
}
