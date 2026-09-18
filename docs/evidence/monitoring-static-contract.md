# Static New Relic observability contract

This is source/contract evidence only. [Monitoring Terraform](../../infra/monitoring/main.tf) now represents the required categories below; its [mocked tests](../../infra/monitoring/tests/monitoring.tftest.hcl) do not contact AWS, Kubernetes or New Relic. No populated dashboard, correlated trace, delivered alert, live synthetic result or R4 acceptance is claimed.

| Requirement | Committed representation |
| --- | --- |
| Daily order volume | `WorkshopReportSnapshot` latest created/eligible/excluded counts, `window_kind = 'day'`, faceted by `business_date` |
| Diagnosis, execution and finalization durations | Total seconds divided by sample count and 60; zero samples excluded. Diagnosis/finalization use daily windows; execution retains the reviewed rolling-seven-day window. No average of daily averages. |
| Integration errors | `Log` count with `event_name = 'integration_failed'`, alongside the existing notification-failure and outbox widgets/conditions |
| API latency | Platform p95 `Transaction.duration` widget and `api_latency` condition: above 2 seconds for 300 seconds. This is a proposed static threshold requiring live calibration before activation. |
| Resources, health and order failures | Existing CPU/memory, unavailable/pending pods, heartbeat loss/drop, outbox and `order_technical_failure` conditions remain present |
| Structured correlation | Aggregate log count requiring `correlation_id`, `api_gateway_request_id`, `traceparent`, `event_name`, `service` and `version`; facet only by service/event name, without selecting raw log payloads or credential fields |
| Synthetics | Existing two `SIMPLE` HTTPS health monitors, one per environment, every minute with `UP` validation; new failure condition counts failed checks for the exact environment monitor name, above zero for 60 seconds |

There are still four dashboards and two synthetic monitors; the condition count rises from 12 to 14. Dashboard variables remain restricted to staging/production. Application and infrastructure alerts bind the concrete Terraform environment. `SyntheticCheck` uses the exact `Oficina <environment> gateway health` monitor name rather than assuming that collector custom attributes exist on synthetic events. Mocked production assertions verify that the new conditions cannot match staging signals.

The finalization field names and correlation allowlist match the reviewed APP [snapshot exporter](https://github.com/rafaelxvr/Tech-challenge-15SOAT/blob/85a7227c94cf322cd1bdab3f2f0cb43099370a81/src/main/java/com/oficina/application/observability/SnapshotScheduler.java) and [JSON log configuration](https://github.com/rafaelxvr/Tech-challenge-15SOAT/blob/85a7227c94cf322cd1bdab3f2f0cb43099370a81/src/main/resources/logback-spring.xml). Field presence in a query does not prove that every emitter supplies it, that `traceparent` produces a navigable New Relic distributed trace, or that the log collector parses and forwards it correctly.

Provider credentials remain sensitive execution inputs; the chart uses the existing Secret reference. Tests supply only a literal mock key and synthetic `.invalid` endpoints. Assertions reject credential-field/raw-payload queries and check that the mock provider key is absent from dashboard and chart values. No secret values are fetched, committed or displayed.

## Offline verification

```powershell
terraform -chdir=infra/monitoring init -backend=false -input=false -lockfile=readonly
terraform -chdir=infra/monitoring fmt -check -recursive
terraform -chdir=infra/monitoring validate
terraform -chdir=infra/monitoring test
pwsh -NoProfile -File tests/newrelic-chart-tests.ps1
```

The test file declares `mock_provider "helm"` and `mock_provider "newrelic"`; every run uses `command = plan`. Initialization downloads pinned provider packages, but no real provider plan/apply or API request is made by the tests. Existing CI already runs this test file.

RED: the new category and production-scoping runs failed against the prior definitions (one existing run passed, two new runs failed). GREEN: the same suite passed all three runs after the minimal definitions were added. The existing chart assertions passed statically on the local Windows runner; Helm is unavailable there, so dynamic chart schema/render accounting remains unverified locally.

## Remaining live evidence

Authorized activation still needs reviewed environment/endpoint/provider inputs, valid cloud access, populated telemetry, observed latency/resource thresholds and meaningful status transitions. Validate the live NRQL results, JSON field ingestion, request-to-trace navigation, both health responses and a bounded synthetic failure. Notification destinations/workflows and actual alert delivery are not established by this module's alert-policy/condition definitions. Keep live dashboard/alert delivery, runtime readiness and R4 acceptance pending until that evidence exists.

New Relic documents [Transaction duration in seconds](https://docs.newrelic.com/docs/nrql/nrql-tutorials/introduction-nrql-tutorial/), [NRQL percentile conditions](https://docs.newrelic.com/docs/alerts/create-alert/create-alert-condition/create-nrql-alert-conditions/) and [synthetic alert configuration](https://docs.newrelic.com/docs/synthetics/synthetic-monitoring/using-monitors/alerts-synthetic-monitoring/). Local string/schema assertions cannot establish server-side NRQL evaluation or notification delivery.
