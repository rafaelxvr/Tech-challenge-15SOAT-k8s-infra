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

run "monitoring_is_pinned_bounded_and_has_four_dashboards" {
  command = plan
  assert {
    condition     = helm_release.nri_bundle.version == "5.0.94" && length(newrelic_one_dashboard.approved) == 4 && length(newrelic_synthetics_monitor.gateway_health) == 2
    error_message = "R2 needs the pinned low-data bundle, four dashboards and one free simple ping per environment."
  }
  assert {
    condition     = strcontains(helm_release.nri_bundle.values[0], "lowDataMode: true") && strcontains(helm_release.nri_bundle.values[0], "customAttributes:\n    environment: staging") && strcontains(helm_release.nri_bundle.values[0], "common:\n    config:\n      interval: 30s") && strcontains(helm_release.nri_bundle.values[0], "pixie-chart:\n  enabled: false") && strcontains(helm_release.nri_bundle.values[0], "prometheus:\n  enabled: false") && !strcontains(helm_release.nri_bundle.values[0], "licenseKey:")
    error_message = "The pinned bundle must use supported 30-second low-data collection, exact environment attributes, approved collectors and an existing Secret reference only."
  }
  assert {
    condition     = length(newrelic_nrql_alert_condition.threshold) == 12 && newrelic_nrql_alert_condition.threshold["outbox_age"].critical[0].threshold == 60 && newrelic_nrql_alert_condition.threshold["missing_heartbeat"].critical[0].operator == "above" && newrelic_nrql_alert_condition.threshold["missing_heartbeat"].critical[0].threshold == 1000000000 && newrelic_nrql_alert_condition.threshold["missing_heartbeat"].expiration_duration == 180 && newrelic_nrql_alert_condition.threshold["missing_heartbeat"].open_violation_on_expiration && newrelic_synthetics_monitor.gateway_health["staging"].period == "EVERY_MINUTE"
    error_message = "A normal heartbeat count must remain nonviolating while three-minute loss-of-signal opens the heartbeat alert."
  }
  assert {
    condition     = helm_release.nri_bundle.postrender[0].binary_path == "pwsh" && strcontains(helm_release.nri_bundle.postrender[0].args[2], "append-newrelic-secret-sync.ps1") && strcontains(helm_release.nri_bundle.postrender[0].args[4], var.ingest_secret_arn) && strcontains(helm_release.nri_bundle.postrender[0].args[4], var.secret_sync_irsa_role_arn)
    error_message = "The same Helm release must render the existing environment Secret sync before collector manifests."
  }
  assert {
    condition     = alltrue([for alert in values(newrelic_nrql_alert_condition.threshold) : strcontains(alert.nrql[0].query, "environment = 'staging'") && !strcontains(alert.nrql[0].query, "{{environment}}")]) && strcontains(newrelic_one_dashboard.approved["platform"].page[0].widget_line[0].nrql_query[0].query, "{{environment}}")
    error_message = "Applied alert NRQL must bind the concrete Terraform environment; dashboards retain their finite interactive environment filter."
  }
}
