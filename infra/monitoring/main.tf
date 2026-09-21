locals {
  approved_environments = ["staging", "production"]
  values_template       = file("${path.module}/../../observability/newrelic-values.yaml")
  bundle_values         = replace(replace(replace(local.values_template, "$${cluster_name}", var.cluster_name), "$${environment}", var.environment), "$${ingest_secret_name}", var.ingest_secret_name)
  secret_sync_manifest  = templatefile("${path.module}/../../observability/newrelic-secret-sync.yaml", { ingest_secret_name = var.ingest_secret_name, ingest_secret_arn = var.ingest_secret_arn, secret_sync_irsa_role_arn = var.secret_sync_irsa_role_arn })
  # The dashboard variable below uses replacement_strategy "string", which wraps the
  # selected value in quotes on substitution. Quoting it again here renders
  # environment = ''staging'', which is invalid NRQL and leaves every widget empty.
  dashboard_nrql = "environment = {{environment}}"
  alert_nrql     = "environment = '${var.environment}'"
  dashboard_widgets = {
    business = [
      { title = "Daily diagnosis mean", query = "FROM WorkshopReportSnapshot SELECT latest(diagnosis_total_seconds) / latest(diagnosis_samples) / 60 WHERE ${local.dashboard_nrql} AND window_kind = 'day' AND diagnosis_samples > 0 FACET business_date SINCE 3 minutes ago" },
      { title = "Rolling execution mean", query = "FROM WorkshopReportSnapshot SELECT latest(execution_total_seconds) / latest(execution_samples) / 60 WHERE ${local.dashboard_nrql} AND window_kind = 'rolling_7_day' AND execution_samples > 0 SINCE 3 minutes ago" },
      { title = "Daily finalization mean", query = "FROM WorkshopReportSnapshot SELECT latest(finalization_total_seconds) / latest(finalization_samples) / 60 WHERE ${local.dashboard_nrql} AND window_kind = 'day' AND finalization_samples > 0 FACET business_date SINCE 3 minutes ago" }
    ]
    orders = [
      { title = "Order volume", query = "FROM WorkshopReportSnapshot SELECT latest(created_count), latest(eligible_count), latest(excluded_count) WHERE ${local.dashboard_nrql} AND window_kind = 'day' FACET business_date SINCE 3 minutes ago" },
      { title = "Status age", query = "FROM WorkshopStatusSnapshot SELECT latest(current_count), latest(max_age_seconds), latest(unknown_age_count) WHERE ${local.dashboard_nrql} FACET status SINCE 3 minutes ago" }
    ]
    delivery = [
      { title = "Outbox blocked", query = "FROM WorkshopOutboxHealth SELECT latest(blocked_count), latest(oldest_pending_seconds) WHERE ${local.dashboard_nrql} SINCE 3 minutes ago" },
      { title = "Function delivery failures", query = "FROM Log SELECT count(*) WHERE ${local.dashboard_nrql} AND event_name = 'notification_failed' SINCE 5 minutes ago" },
      { title = "Integration errors", query = "FROM Log SELECT count(*) WHERE ${local.dashboard_nrql} AND event_name = 'integration_failed' SINCE 5 minutes ago" }
    ]
    platform = [
      { title = "Kubernetes capacity", query = "FROM K8sContainerSample SELECT average(cpuUsedCores), average(memoryWorkingSetBytes) WHERE ${local.dashboard_nrql} FACET clusterName SINCE 5 minutes ago" },
      { title = "Telemetry heartbeat", query = "FROM WorkshopTelemetryHeartbeat SELECT latest(drop_count) WHERE ${local.dashboard_nrql} SINCE 3 minutes ago" },
      { title = "API p95 latency seconds", query = "FROM Transaction SELECT percentile(duration, 95) WHERE ${local.dashboard_nrql} SINCE 5 minutes ago" },
      { title = "Correlated request logs", query = "FROM Log SELECT count(*) WHERE ${local.dashboard_nrql} AND correlation_id IS NOT NULL AND api_gateway_request_id IS NOT NULL AND traceparent IS NOT NULL AND event_name IS NOT NULL AND service IS NOT NULL AND version IS NOT NULL FACET service, event_name SINCE 5 minutes ago" }
    ]
  }
  alert_conditions = {
    order_technical_failures = { query = "FROM Log SELECT count(*) WHERE ${local.alert_nrql} AND event_name = 'order_technical_failure'", threshold = 0, duration = 60, expiration = null }
    api_error_ratio          = { query = "FROM Transaction SELECT percentage(count(*), WHERE httpResponseCode >= 500) WHERE ${local.alert_nrql}", threshold = 5, duration = 300, expiration = null }
    api_latency              = { query = "FROM Transaction SELECT percentile(duration, 95) WHERE ${local.alert_nrql}", threshold = 2, duration = 300, expiration = null }
    # SyntheticCheck does not inherit the collector's environment attribute.
    # Bind the exact environment monitor name instead of an absent attribute.
    gateway_health_failure   = { query = "FROM SyntheticCheck SELECT filter(count(*), WHERE result = 'FAILED') WHERE monitorName = 'Oficina ${var.environment} gateway health'", threshold = 0, duration = 60, expiration = null }
    outbox_blocked           = { query = "FROM WorkshopOutboxHealth SELECT latest(blocked_count) WHERE ${local.alert_nrql}", threshold = 0, duration = 60, expiration = null }
    outbox_age               = { query = "FROM WorkshopOutboxHealth SELECT latest(oldest_pending_seconds) WHERE ${local.alert_nrql}", threshold = 60, duration = 120, expiration = null }
    container_memory         = { query = "FROM K8sContainerSample SELECT max(memoryWorkingSetBytes / memoryLimitBytes * 100) WHERE ${local.alert_nrql}", threshold = 85, duration = 300, expiration = null }
    node_cpu                 = { query = "FROM K8sNodeSample SELECT max(cpuUsedCores / allocatableCpuCores * 100) WHERE ${local.alert_nrql}", threshold = 85, duration = 300, expiration = null }
    pending_unavailable_pods = { query = "FROM K8sPodSample SELECT latest(pendingPods) + latest(unavailablePods) WHERE ${local.alert_nrql}", threshold = 0, duration = 120, expiration = null }
    integration_failures     = { query = "FROM Log SELECT count(*) WHERE ${local.alert_nrql} AND event_name = 'integration_failed'", threshold = 0, duration = 60, expiration = null }
    # Numeric evaluation can never violate during normal operation. Loss-of-signal is the only
    # violation path and opens after three minutes without a heartbeat event.
    missing_heartbeat  = { query = "FROM WorkshopTelemetryHeartbeat SELECT count(*) WHERE ${local.alert_nrql}", threshold = 1000000000, duration = 60, expiration = 180 }
    telemetry_drop     = { query = "FROM WorkshopTelemetryHeartbeat SELECT latest(drop_count) WHERE ${local.alert_nrql}", threshold = 0, duration = 60, expiration = null }
    telemetry_usage_50 = { query = "FROM NrConsumption SELECT latest(gigabytesIngested) WHERE ${local.alert_nrql}", threshold = 1.5, duration = 60, expiration = null }
    telemetry_usage_80 = { query = "FROM NrConsumption SELECT latest(gigabytesIngested) WHERE ${local.alert_nrql}", threshold = 2.4, duration = 60, expiration = null }
  }
}

resource "helm_release" "nri_bundle" {
  name             = "nri-bundle"
  namespace        = "newrelic"
  create_namespace = true
  repository       = "https://helm-charts.newrelic.com"
  chart            = "nri-bundle"
  version          = "5.0.94"
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600
  values           = [local.bundle_values]
  # Helm applies the post-rendered SecretProviderClass/sync workload in this same release graph.
  postrender {
    binary_path = "pwsh"
    args        = ["-NoProfile", "-File", "${path.module}/../../scripts/append-newrelic-secret-sync.ps1", "-Manifest", local.secret_sync_manifest]
  }
}

resource "newrelic_one_dashboard" "approved" {
  for_each = local.dashboard_widgets
  name     = "Oficina Phase 3 ${title(each.key)}"
  page {
    name = "Overview"
    dynamic "widget_line" {
      for_each = each.value
      content {
        title  = widget_line.value.title
        row    = index(each.value, widget_line.value) + 1
        column = 1
        width  = 12
        height = 3
        nrql_query { query = widget_line.value.query }
      }
    }
  }
  variable {
    name                 = "environment"
    title                = "Environment"
    type                 = "enum"
    replacement_strategy = "string"
    default_values       = [var.environment]
    is_multi_selection   = false
    item {
      title = "Staging"
      value = "staging"
    }
    item {
      title = "Production"
      value = "production"
    }
  }
}

resource "newrelic_alert_policy" "operations" { name = "Oficina Phase 3 ${var.environment} operations" }

resource "newrelic_nrql_alert_condition" "threshold" {
  for_each  = local.alert_conditions
  policy_id = newrelic_alert_policy.operations.id
  type      = "static"
  name      = replace(each.key, "_", " ")
  nrql { query = each.value.query }
  critical {
    operator              = "above"
    threshold             = each.value.threshold
    threshold_duration    = each.value.duration
    threshold_occurrences = "ALL"
  }
  fill_option = "none"
  # Heartbeat absence is a signal loss; other missing provider metrics remain unknown/no-data.
  expiration_duration            = each.value.expiration
  open_violation_on_expiration   = each.value.expiration != null ? true : null
  close_violations_on_expiration = each.value.expiration != null ? true : null
  aggregation_window             = 60
  aggregation_method             = "event_flow"
  # event_flow batches by event timestamp, so it needs an explicit delay to wait for
  # late-arriving events before it closes a window. New Relic rejects the condition
  # without one. Two minutes covers the agent and Lambda extension harvest cycles.
  aggregation_delay            = 120
  violation_time_limit_seconds = 3600
}

resource "newrelic_synthetics_monitor" "gateway_health" {
  for_each          = var.gateway_health_urls
  name              = "Oficina ${each.key} gateway health"
  type              = "SIMPLE"
  period            = "EVERY_MINUTE"
  status            = "ENABLED"
  uri               = each.value
  locations_public  = ["AWS_US_EAST_1"]
  validation_string = "UP"
}
