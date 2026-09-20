# Staging alert delivery source contract

This is local source evidence only. Delivery has not been activated or observed. Runtime readiness and R4 acceptance remain pending.

[Delivery resources](../../infra/monitoring/alert-delivery.tf) add one EMAIL destination, one IINT notification channel and one workflow when `alert_delivery_enabled = true`. The workflow filters `labels.policyIds` with `EXACTLY_MATCHES` against the existing `newrelic_alert_policy.operations.id`; it sends ACTIVATED/CLOSED events and respects fully muted issues. Existing dashboards, conditions and synthetics are unchanged.

Both staging and production default to zero notification resources. Production enablement is explicitly rejected in this change. An empty recipient is valid only while disabled; enabling staging requires one reviewed email address. Lists, display names, whitespace and malformed addresses fail validation.

Supply the real recipient only through the protected execution input `TF_VAR_alert_email_recipient`, alongside the existing protected provider credentials. No real recipient or credential is committed. Terraform marks the recipient sensitive, but sensitivity is output redaction, not state encryption: the destination email persists in Terraform state and must be protected by the backend access/encryption controls. Do not publish plan/state bodies or place the recipient in committed tfvars, chart values or evidence receipts.

## Offline checks

```powershell
terraform -chdir=infra/monitoring init -backend=false -input=false -lockfile=readonly
terraform -chdir=infra/monitoring fmt -check -recursive
terraform -chdir=infra/monitoring validate
terraform -chdir=infra/monitoring test
```

[Delivery tests](../../infra/monitoring/tests/alert-delivery.tftest.hcl) mock both providers and use plan-only runs, including plan-time ID overrides for resource relationships. They prove the disabled defaults, the three-resource staging route, missing/malformed/multiple recipient rejection, and production rejection. The full module suite passes 10 runs with zero failures. Tests use `operations@example.invalid` and a literal mock API key only. Run with canonical LF checkout bytes: the existing chart string assertions are sensitive to Windows CRLF; no chart source change is part of this task. A filtered test invocation on the local Windows Terraform runner discovered zero runs, so validation uses the full suite and checks the nonzero run count.

Schema was checked against the locally installed, lock-pinned New Relic provider 3.57.0. Its official versioned documentation defines the [email destination](https://github.com/newrelic/terraform-provider-newrelic/blob/v3.57.0/website/docs/r/notification_destination.html.markdown), [notification channel](https://github.com/newrelic/terraform-provider-newrelic/blob/v3.57.0/website/docs/r/notification_channel.html.markdown), and [workflow policy filter](https://github.com/newrelic/terraform-provider-newrelic/blob/v3.57.0/website/docs/r/workflow.html.markdown). Initialization used an existing local provider mirror and left committed lock bytes unchanged.

## Activation evidence still required

A separate reviewed staging plan needs the protected recipient, account/API permissions, backend protections and explicit enablement. After separately authorized activation, record destination/channel/workflow IDs, a bounded issue activation/recovery and actual delivery receipt. No apply, AWS/New Relic API execution, email delivery or production activation was performed by this task.
