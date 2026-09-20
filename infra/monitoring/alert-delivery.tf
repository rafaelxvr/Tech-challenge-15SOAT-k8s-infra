variable "alert_delivery_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "Explicit reviewed staging-only delivery gate. Production activation requires a separate change."
  validation {
    condition     = !var.alert_delivery_enabled || var.environment == "staging"
    error_message = "Alert delivery may be enabled only for staging in this contract."
  }
}

variable "alert_email_recipient" {
  type        = string
  default     = ""
  nullable    = false
  sensitive   = true
  description = "Single reviewed operations email, supplied through protected TF_VAR_alert_email_recipient; never committed in tfvars. Persisted in protected Terraform state when enabled."
  validation {
    condition = (!var.alert_delivery_enabled && var.alert_email_recipient == "") || (
      length(var.alert_email_recipient) <= 254 &&
      can(regex("^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$", var.alert_email_recipient))
    )
    error_message = "Enabling delivery requires one nonempty reviewed email address, without whitespace, display name or recipient lists."
  }
}

resource "newrelic_notification_destination" "operations" {
  count      = var.alert_delivery_enabled ? 1 : 0
  account_id = var.newrelic_account_id
  name       = "Oficina ${var.environment} operations email"
  type       = "EMAIL"
  property {
    key   = "email"
    value = var.alert_email_recipient
  }
}

resource "newrelic_notification_channel" "operations" {
  count          = var.alert_delivery_enabled ? 1 : 0
  account_id     = var.newrelic_account_id
  name           = "Oficina ${var.environment} operations"
  type           = "EMAIL"
  product        = "IINT"
  destination_id = newrelic_notification_destination.operations[0].id
  property {
    key   = "subject"
    value = "Oficina ${var.environment} operations issue"
  }
}

resource "newrelic_workflow" "operations" {
  count                 = var.alert_delivery_enabled ? 1 : 0
  account_id            = var.newrelic_account_id
  name                  = "Oficina ${var.environment} operations delivery"
  enabled               = true
  muting_rules_handling = "DONT_NOTIFY_FULLY_MUTED_ISSUES"
  issues_filter {
    name = "Existing ${var.environment} operations policy only"
    type = "FILTER"
    predicate {
      attribute = "labels.policyIds"
      operator  = "EXACTLY_MATCHES"
      values    = [newrelic_alert_policy.operations.id]
    }
  }
  destination {
    channel_id            = newrelic_notification_channel.operations[0].id
    notification_triggers = ["ACTIVATED", "CLOSED"]
  }
}
