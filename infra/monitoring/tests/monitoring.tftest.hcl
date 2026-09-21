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
    condition     = length(newrelic_nrql_alert_condition.threshold) == 14 && newrelic_nrql_alert_condition.threshold["outbox_age"].critical[0].threshold == 60 && newrelic_nrql_alert_condition.threshold["missing_heartbeat"].critical[0].operator == "above" && newrelic_nrql_alert_condition.threshold["missing_heartbeat"].critical[0].threshold == 1000000000 && newrelic_nrql_alert_condition.threshold["missing_heartbeat"].expiration_duration == 180 && newrelic_nrql_alert_condition.threshold["missing_heartbeat"].open_violation_on_expiration && newrelic_synthetics_monitor.gateway_health["staging"].period == "EVERY_MINUTE"
    error_message = "A normal heartbeat count must remain nonviolating while three-minute loss-of-signal opens the heartbeat alert."
  }
  assert {
    condition     = helm_release.nri_bundle.postrender[0].binary_path == "pwsh" && strcontains(helm_release.nri_bundle.postrender[0].args[2], "append-newrelic-secret-sync.ps1") && strcontains(helm_release.nri_bundle.postrender[0].args[4], var.ingest_secret_arn) && strcontains(helm_release.nri_bundle.postrender[0].args[4], var.secret_sync_irsa_role_arn)
    error_message = "The same Helm release must render the existing environment Secret sync before collector manifests."
  }
  assert {
    condition     = alltrue([for name, alert in local.alert_conditions : (name == "gateway_health_failure" ? strcontains(alert.query, "monitorName = 'Oficina staging gateway health'") : contains(["api_latency", "api_error_ratio"], name) ? strcontains(alert.query, "appName = 'oficina-api-staging'") : strcontains(alert.query, "environment = 'staging'")) && !strcontains(alert.query, "{{environment}}")]) && strcontains(newrelic_one_dashboard.approved["platform"].page[0].widget_line[0].nrql_query[0].query, "{{environment}}")
    error_message = "Applied alert NRQL must bind the concrete Terraform environment or its exact synthetic monitor; dashboards retain their finite interactive environment filter."
  }
  assert {
    condition = alltrue([for widget in flatten(values(local.dashboard_widgets)) :
    !strcontains(widget.query, "'{{environment}}'")])
    error_message = "The environment variable substitutes with replacement_strategy \"string\", which adds its own quotes. Quoting it in the query renders environment = ''staging'' and empties every widget."
  }
}
run "required_observability_categories_are_represented" {
  command = plan

  assert {
    condition = anytrue([for widget in local.dashboard_widgets.business :
      strcontains(widget.query, "latest(finalization_total_seconds) / latest(finalization_samples) / 60") &&
      strcontains(widget.query, "finalization_samples > 0") && strcontains(widget.query, "window_kind = 'day'")
    ])
    error_message = "The finalization duration dashboard must use totals/samples in minutes with a positive-sample guard."
  }
  assert {
    condition = anytrue([for widget in local.dashboard_widgets.delivery :
      strcontains(widget.query, "FROM Log SELECT count(*)") && strcontains(widget.query, "event_name = 'integration_failed'")
    ])
    error_message = "The delivery dashboard must represent integration failures, not notification failures alone."
  }
  assert {
    condition = try(
      strcontains(local.alert_conditions["api_latency"].query, "FROM Transaction SELECT percentile(duration, 95)") &&
      local.alert_conditions["api_latency"].threshold == 2 &&
      local.alert_conditions["api_latency"].duration == 300,
      false
    )
    error_message = "API p95 latency must have an explicit two-second/five-minute condition."
  }
  assert {
    condition = anytrue([for widget in local.dashboard_widgets.platform : alltrue([
      for field in ["correlation_id", "api_gateway_request_id", "traceparent", "event_name", "service", "version"] :
      strcontains(widget.query, "${field} IS NOT NULL")
    ]) && strcontains(widget.query, "FROM Log SELECT count(*)")])
    error_message = "A structured-log correlation query must require request, trace, event, service and version fields without selecting raw payloads."
  }
  assert {
    condition = try(
      local.alert_conditions["gateway_health_failure"].query == "FROM SyntheticCheck SELECT filter(count(*), WHERE result = 'FAILED') WHERE monitorName = 'Oficina staging gateway health'" &&
      local.alert_conditions["gateway_health_failure"].threshold == 0 &&
      local.alert_conditions["gateway_health_failure"].duration == 60,
      false
    )
    error_message = "A failed synthetic ping needs an explicit alert scoped to the staging monitor."
  }
  assert {
    condition = anytrue([for widget in local.dashboard_widgets.orders :
      strcontains(widget.query, "latest(created_count)") && strcontains(widget.query, "window_kind = 'day'") && strcontains(widget.query, "FACET business_date")
      ]) && alltrue([for status in ["diagnosis", "execution"] : anytrue([
        for widget in local.dashboard_widgets.business : strcontains(widget.query, "latest(${status}_total_seconds) / latest(${status}_samples) / 60") && strcontains(widget.query, "${status}_samples > 0")
    ])])
    error_message = "Daily order volume and diagnosis/execution duration definitions must remain represented."
  }
  assert {
    condition = alltrue([for name in ["order_technical_failures", "integration_failures", "container_memory", "node_cpu", "pending_unavailable_pods", "missing_heartbeat"] :
      contains(keys(newrelic_nrql_alert_condition.threshold), name)
      ]) && alltrue([for monitor in values(newrelic_synthetics_monitor.gateway_health) :
      monitor.type == "SIMPLE" && monitor.period == "EVERY_MINUTE" && monitor.validation_string == "UP" && monitor.status == "ENABLED"
    ])
    error_message = "Order/integration/resource/health conditions and bounded health synthetics must remain represented."
  }
  assert {
    condition = alltrue([for name, definition in local.alert_conditions :
      newrelic_nrql_alert_condition.threshold[name].nrql[0].query == definition.query &&
      newrelic_nrql_alert_condition.threshold[name].critical[0].threshold == definition.threshold &&
      newrelic_nrql_alert_condition.threshold[name].critical[0].threshold_duration == definition.duration
    ]) && alltrue([for environment, monitor in newrelic_synthetics_monitor.gateway_health : monitor.name == "Oficina ${environment} gateway health"])
    error_message = "The planned conditions must retain the tested queries/thresholds and exact synthetic monitor identities."
  }
  # Kept apart from the secret check below: an assertion that references the sensitive
  # provider key cannot render its own failure diff, so a scoping regression would crash
  # the test run instead of reporting which widget broke.
  assert {
    condition = alltrue([for widget in flatten(values(local.dashboard_widgets)) :
      (strcontains(widget.query, "environment = {{environment}}") || strcontains(widget.query, "appName = 'oficina-api-${var.environment}'")) &&
      !can(regex("(?i)select[[:space:]]+\\*|password|authorization|access_token|license.?key|api.?key", widget.query))
    ])
    error_message = "Every dashboard query must scope to the environment variable or to the environment application entity, and must not select raw payload or credential fields."
  }
  assert {
    condition = (!strcontains(jsonencode(local.dashboard_widgets), nonsensitive(var.newrelic_api_key)) &&
    !strcontains(helm_release.nri_bundle.values[0], nonsensitive(var.newrelic_api_key)))
    error_message = "Rendered dashboards and collector values must never contain the provider key."
  }
}

run "production_conditions_cannot_match_staging_signals" {
  command = plan
  variables {
    environment               = "production"
    ingest_secret_name        = "newrelic-production-ingest"
    ingest_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/production/newrelic-ingest-AbCdEf"
    secret_sync_irsa_role_arn = "arn:aws:iam::123456789012:role/oficina-production-newrelic-secret-sync"
  }
  assert {
    condition = try(
      strcontains(local.alert_conditions["api_latency"].query, "appName = 'oficina-api-production'") &&
      strcontains(local.alert_conditions["outbox_age"].query, "environment = 'production'") &&
      local.alert_conditions["gateway_health_failure"].query == "FROM SyntheticCheck SELECT filter(count(*), WHERE result = 'FAILED') WHERE monitorName = 'Oficina production gateway health'",
      false
    )
    error_message = "Production latency and synthetic conditions must bind production only; this is a mocked plan, not a deployment."
  }
}
