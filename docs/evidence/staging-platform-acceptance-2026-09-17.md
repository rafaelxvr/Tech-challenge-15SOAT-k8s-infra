# Staging platform acceptance evidence

Generated: `2026-09-18T00:28:42Z`

This record captures the successful K8S staging platform run only. It does not attest to application, Functions, database, Kubernetes pod readiness, IRSA/CSI access, or end-to-end runtime behavior.

## Source and execution evidence

| Field | Reviewed value |
| --- | --- |
| GitHub Actions run | [35290898261](https://github.com/rafaelxvr/Tech-challenge-15SOAT-k8s-infra/actions/runs/35290898261) |
| K8S CodeBuild project | `oficina-phase3-oficina-k8s-infra-staging-deploy` |
| K8S CodeBuild build | `1adfe0ed-fde6-4ac7-9a9b-b605b2a9142c` (`SUCCEEDED`) |
| K8S source commit | `687ef6bb17ae48b010346c28a7361ac0b0f5c75f` |
| K8S source object version | `MOjHpTBPfYzpsFqrx1nEjE3jRjhGyyCa` |
| K8S Terraform state key | `environments/staging.tfstate` |
| K8S Terraform state object version | `SPRykOORYtK8CjJhzCAnE560GeqHyhSj` |
| K8S Terraform state last modified | `2026-09-18T00:28:27Z` |
| Foundation-addons CodeBuild project | `oficina-phase3-foundation-addons` |
| Foundation-addons build | `ce09aea5-6098-4877-af19-f32cee9b2414` (`SUCCEEDED`) |
| Foundation-addons source commit | `687ef6bb17ae48b010346c28a7361ac0b0f5c75f` |
| Foundation-addons manifest object version | `agDIgGPvKkyC9X1vGvX.wz_iDtd3tX_N` |

The build log recorded Terraform initialization, validation, refresh, and `Apply complete! Resources: 0 added, 0 changed, 0 destroyed.` The K8S CodeBuild log is available in [CloudWatch](https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:log-groups/log-group/$252Faws$252Fcodebuild$252Foficina-phase3-oficina-k8s-infra-staging-deploy/log-events/deploy$252F1adfe0ed-fde6-4ac7-9a9b-b605b2a9142c).

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

The refreshed deployment executor was applied from source commit `687ef6bb17ae48b010346c28a7361ac0b0f5c75f`. A follow-up Functions-only staging deployment must verify that the executor supplies `ExpectedTerraformVariablesSha256` to the Functions deployer while preserving the K8S and database deployment paths.

## Runtime acceptance status

| Area | Status | Reason |
| --- | --- | --- |
| APP application runtime | **NOT_RUN** | No application runtime acceptance record is included in this K8S platform run. |
| FUN serverless runtime | **NOT_RUN** | No Functions deployment or API authorizer acceptance record is included. |
| DB database runtime | **NOT_RUN** | No database deployment, migration, schema, or connectivity acceptance record is included. |
