# K8S requirement and evidence matrix

Source audit 2026-09-16 at `47fb380`. [Historical R4 status](r4-local-status.json) is not a current AWS inventory. No live outcome is inferred here; see the [central matrix](../../../Tech-challenge-15SOAT/docs/phase-3/evidence/requirements.md).

| Requirement | Source evidence | Acceptance gap |
| --- | --- | --- |
| Exact identity/state boundaries | [Bootstrap](../bootstrap.md), [executor module](../../infra/modules/deployment-executor) | Actual protected branches/environments, immutable OIDC subjects and reviewed role permissions. |
| Bounded topology | [Network/capacity rationale](../network-capacity.md), [foundation](../../infra/foundation) | Actual routing, quotas, EKS allocatable capacity and cost/window evidence. |
| APP rollout | [Workload contract](../platform-workloads.md), [rollout tests](../../tests/application-rollout-tests.ps1) | IRSA/CSI access, public-key configuration, first-writer migration and live probes/HPA. |
| Route and state ownership | [Architecture](../architecture.md), [gateway tests](../../tests/gateway-contract-tests.ps1) | FUN single-owner handoff and live authenticated API cases. |
| Release/monitoring | [Deployment sequence](../deployment-sequence.md), [lock race test](../../tests/deployment-lock-race-contract.ps1), [monitoring](../../infra/monitoring) | Rebuild/review CLI 2.36.42 deployer digest, terminal deployment receipts and actual alert delivery. |

[Release readiness](../release-readiness.md) and the [central runbook](../../../Tech-challenge-15SOAT/docs/phase-3/runbooks/release-operations.md) define inspected recovery, evidence and cleanup boundaries. Source authoring never authorizes production or teardown. Run the APP stdlib link checker across the four sibling checkouts before publishing these documents.
