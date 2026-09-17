# Staging platform acceptance evidence

Generated: `2026-09-17T20:02:49-03:00`

This record captures the successful K8S staging platform run only. It does not attest to application, Functions, database, Kubernetes pod readiness, IRSA/CSI access, or end-to-end runtime behavior.

## Source and execution evidence

| Field | Reviewed value |
| --- | --- |
| GitHub Actions run | [35284614823](https://github.com/rafaelxvr/Tech-challenge-15SOAT-k8s-infra/actions/runs/35284614823) |
| K8S CodeBuild project | `oficina-phase3-oficina-k8s-infra-staging-deploy` |
| K8S CodeBuild build | `1a43b70d-f74c-40e4-a580-1abf23d7df66` (`SUCCEEDED`) |
| K8S source commit | `64232aed9c6e2bf811474cba129a10aede7695f6` |
| K8S source object version | `Bg3a2O4UdIhzX8qx8umwSBwF0bHXgt2_` |
| K8S Terraform state key | `environments/staging.tfstate` |
| K8S Terraform state object version | `gr9dvSN7rpWN3LG_UhAkL55gwiu_qSgq` |
| K8S Terraform state last modified | `2026-09-17T23:00:27Z` |
| Foundation-addons CodeBuild project | `oficina-phase3-foundation-addons` |
| Foundation-addons build | `b8041b5b-e0a3-439b-8c4d-cc2e57f0b790` (`SUCCEEDED`) |
| Foundation-addons source commit | `64232aed9c6e2bf811474cba129a10aede7695f6` |
| Foundation-addons manifest object version | `fTtJEKkH8c0MX62GVG6HwkkYZDhZT7Kp` |

The build log recorded Terraform initialization, validation, refresh, and `Apply complete! Resources: 0 added, 0 changed, 0 destroyed.` The K8S CodeBuild log is available in [CloudWatch](https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:log-groups/log-group/$252Faws$252Fcodebuild$252Foficina-phase3-oficina-k8s-infra-staging-deploy/log-events/deploy$252F1a43b70d-f74c-40e4-a580-1abf23d7df66).

## Staging K8S platform result

| Output | Observed value |
| --- | --- |
| API ID | `qcm8l43flb` |
| API endpoint | `https://qcm8l43flb.execute-api.us-east-1.amazonaws.com` |
| API execution ARN | `arn:aws:execute-api:us-east-1:638612472889:qcm8l43flb` |
| Target group ARN | `arn:aws:elasticloadbalancing:us-east-1:638612472889:targetgroup/oficina-phase3-staging-app/89aa626679da1308` |
| Backend listener ARN | `arn:aws:elasticloadbalancing:us-east-1:638612472889:listener/app/oficina-phase3-internal/ab5a1a42559de814/0ca177523a364342` |
| Backend listener port | `8080` |
| Kubernetes namespace | `oficina-staging` |
| K8S staging platform acceptance | **PASS** |

This PASS covers the successful reviewed staging platform Terraform execution and its recorded nonsecret outputs. It does not claim healthy application targets or protected-route behavior.

## Runtime acceptance status

| Area | Status | Reason |
| --- | --- | --- |
| APP application runtime | **NOT_RUN** | No application runtime acceptance record is included in this K8S platform run. |
| FUN serverless runtime | **NOT_RUN** | No Functions deployment or API authorizer acceptance record is included. |
| DB database runtime | **NOT_RUN** | No database deployment, migration, schema, or connectivity acceptance record is included. |
