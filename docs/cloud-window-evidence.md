# Cloud-window evidence

`scripts/check-cloud-window.ps1` accepts two cost-authorization formats. Record the authorization actually given; do not invent a USD cap when the user approved study staging and acknowledged billing beyond free credits without specifying a cap. An evidence record documents an existing approval and does not create authorization by itself.

Both formats require `windowStartUtc`, `windowEndUtc`, `recordedAtUtc`, and `accountEvidenceReference`. Use explicit UTC timestamps from the current review. The start must precede the end and the current time must be inside that window. The account record must be no older than 24 hours and no more than five minutes in the future. These checks apply unchanged to both formats. An expired approval requires a newly approved window, not an automatically extended timestamp.

## Numeric budget (existing format)

Keep the existing `projectAllowanceUsd`, `reserveUsd`, and `currentEstimatedSpendUsd` fields. `costAuthorization` can be omitted for compatibility or set to `numeric-budget`. Allowance must be positive, reserve and spend nonnegative, reserve less than allowance, and spend no greater than allowance minus reserve. The existing production release and promotion checks still apply. Selecting billing acknowledgment never silently overrides a supplied numeric budget.

## Explicit billing acknowledgment for study staging

Use this structure only when the user explicitly authorized the staging study rehearsal and possible charges beyond free credits. The placeholders below are documentation, not usable approval evidence:

```json
{
  "windowStartUtc": "<approved-window-start-in-UTC>",
  "windowEndUtc": "<approved-window-end-in-UTC>",
  "recordedAtUtc": "<fresh-account-review-time-in-UTC>",
  "accountEvidenceReference": "<durable-reference-to-current-account-evidence>",
  "costAuthorization": "billing-acknowledgment",
  "environment": "staging",
  "scope": "study-staging",
  "billingBeyondFreeCreditsAcknowledged": true,
  "approvalReference": "<durable-reference-to-explicit-user-staging-and-billing-approval>"
}
```

The acknowledgment must be JSON boolean `true`, not a string or number. The approval reference must identify the explicit user approval, independently of the fresh account-evidence reference. Omit all three numeric-budget fields in this mode: mixing formats is rejected instead of ignoring an apparent limit. Unknown cost modes, missing approval, broader scope, or a production target are rejected.

Invoke the validator with the actual target:

```powershell
./scripts/check-cloud-window.ps1 -EvidenceFile /path/to/current-evidence.json -Environment staging
```

`start-deploy.ps1` passes its selected environment to this check. The foundation-addons launcher passes `staging` because that execution is a prerequisite of the approved staging rehearsal; it does not introduce a separate foundation environment or approve production deployment. Billing-acknowledgment evidence cannot pass without the explicit staging target, and it cannot pass for a production release even when that release has valid promotion evidence. Reviewed artifact, exact project, time-window, plan, scope, and other deployment safeguards remain required; this format changes only how cost authorization is documented. It does not authorize unrelated resources or operations.

Keep actual account and approval records in the protected release evidence location. Do not echo their contents in CI logs. This change supplies no live approval record and performs no AWS calls.

Run the focused offline checks with `pwsh -NoProfile -File tests/cloud-window-tests.ps1`; `tests/pipeline-contract.ps1` also runs these checks and validates staging/addons acceptance and production rejection through the launchers using dry runs.
