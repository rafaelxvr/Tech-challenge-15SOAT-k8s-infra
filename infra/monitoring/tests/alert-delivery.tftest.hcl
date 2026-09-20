mock_provider "helm" {}
mock_provider "newrelic" {}

variables {
  cluster_name              = "oficina-phase3"
  cluster_endpoint          = "https://example.invalid"
  cluster_ca_certificate    = "Y2E="
  environment               = "staging"
  ingest_secret_name        = "newrelic-staging-ingest"
  ingest_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-AbCdEf"
  secret_sync_irsa_role_arn = "arn:aws:iam::123456789012:role/oficina-staging-newrelic-secret-sync"
  gateway_health_urls       = { staging = "https://staging.example.invalid/health", production = "https://production.example.invalid/health" }
  newrelic_account_id       = 1234567
  newrelic_api_key          = "mock-api-key-only"
}

override_resource {
  target          = newrelic_alert_policy.operations
  override_during = plan
  values          = { id = "123456" }
}

override_resource {
  target          = newrelic_notification_destination.operations
  override_during = plan
  values          = { id = "mock-destination-id" }
}

override_resource {
  target          = newrelic_notification_channel.operations
  override_during = plan
  values          = { id = "mock-channel-id" }
}

run "empty_default_creates_no_notification_resources" {
  command = plan
  assert {
    condition     = length(newrelic_notification_destination.operations) == 0 && length(newrelic_notification_channel.operations) == 0 && length(newrelic_workflow.operations) == 0
    error_message = "Default empty recipient and disabled gate must create no delivery resources."
  }
}

run "enabled_staging_routes_only_existing_operations_policy" {
  command = plan
  variables {
    alert_delivery_enabled = true
    alert_email_recipient  = "operations@example.invalid"
  }
  assert {
    condition     = length(newrelic_notification_destination.operations) == 1 && length(newrelic_notification_channel.operations) == 1 && length(newrelic_workflow.operations) == 1
    error_message = "Exactly one destination, channel and workflow are required."
  }
  assert {
    condition     = newrelic_notification_destination.operations[0].type == "EMAIL" && newrelic_notification_destination.operations[0].account_id == var.newrelic_account_id && one(newrelic_notification_destination.operations[0].property).key == "email" && one(newrelic_notification_destination.operations[0].property).value == var.alert_email_recipient
    error_message = "Recipient must come only from the protected input."
  }
  assert {
    condition     = newrelic_notification_channel.operations[0].type == "EMAIL" && newrelic_notification_channel.operations[0].product == "IINT" && newrelic_notification_channel.operations[0].destination_id == newrelic_notification_destination.operations[0].id
    error_message = "The email channel must bind the created notification destination."
  }
  assert {
    condition     = one(one(newrelic_workflow.operations[0].issues_filter).predicate).attribute == "labels.policyIds" && one(one(newrelic_workflow.operations[0].issues_filter).predicate).operator == "EXACTLY_MATCHES" && one(one(one(newrelic_workflow.operations[0].issues_filter).predicate).values) == newrelic_alert_policy.operations.id
    error_message = "Workflow must route only the existing operations policy ID."
  }
  assert {
    condition     = one(newrelic_workflow.operations[0].destination).channel_id == newrelic_notification_channel.operations[0].id && newrelic_workflow.operations[0].enabled && newrelic_workflow.operations[0].muting_rules_handling == "DONT_NOTIFY_FULLY_MUTED_ISSUES" && toset(one(newrelic_workflow.operations[0].destination).notification_triggers) == toset(["ACTIVATED", "CLOSED"])
    error_message = "Respect fully muted issues and send bounded activation/recovery events."
  }
  assert {
    condition     = !strcontains(one(newrelic_notification_destination.operations[0].property).value, var.newrelic_api_key) && !strcontains(one(newrelic_notification_channel.operations[0].property).value, var.newrelic_api_key) && !strcontains(jsonencode(one(one(newrelic_workflow.operations[0].issues_filter).predicate).values), var.newrelic_api_key) && !strcontains(local.bundle_values, var.alert_email_recipient) && length(newrelic_one_dashboard.approved) == 4 && length(newrelic_nrql_alert_condition.threshold) == 14
    error_message = "No provider credential reaches notification configuration; recipient stays out of chart values; existing dashboards/conditions remain unchanged."
  }
}

run "enabled_without_recipient_rejected" {
  command = plan
  variables { alert_delivery_enabled = true }
  expect_failures = [var.alert_email_recipient]
}

run "multiple_recipients_rejected" {
  command = plan
  variables {
    alert_delivery_enabled = true
    alert_email_recipient  = "first@example.invalid,second@example.invalid"
  }
  expect_failures = [var.alert_email_recipient]
}

run "malformed_recipient_rejected" {
  command = plan
  variables {
    alert_delivery_enabled = true
    alert_email_recipient  = "not-an-email"
  }
  expect_failures = [var.alert_email_recipient]
}

run "production_default_stays_disabled" {
  command = plan
  variables {
    environment        = "production"
    ingest_secret_name = "newrelic-production-ingest"
    ingest_secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/production/newrelic-ingest-AbCdEf"
  }
  assert {
    condition     = length(newrelic_notification_destination.operations) == 0 && length(newrelic_notification_channel.operations) == 0 && length(newrelic_workflow.operations) == 0
    error_message = "Production must remain unchanged and disabled by default."
  }
}

run "production_enablement_rejected" {
  command = plan
  variables {
    environment            = "production"
    ingest_secret_name     = "newrelic-production-ingest"
    ingest_secret_arn      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/production/newrelic-ingest-AbCdEf"
    alert_delivery_enabled = true
    alert_email_recipient  = "operations@example.invalid"
  }
  expect_failures = [var.alert_delivery_enabled]
}
