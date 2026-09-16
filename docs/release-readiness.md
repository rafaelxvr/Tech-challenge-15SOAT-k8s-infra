# Release-readiness handoff

This repository contains reviewed infrastructure definitions and deployment controls. It does **not** prove that AWS resources, GitHub protections, environments, or a deployment exist. No cloud deployment has been performed from this repository. R4 is the only acceptance task that may record real deployment results after the reviewed artifacts, a bounded cloud window, and explicit authorization are available.

## Local release gate

Run this proof before requesting an external release setup or an R4 deployment window:

```powershell
pwsh ./tests/pipeline-contract.ps1
pwsh ./tests/release-readiness-contract.ps1
terraform fmt -check -recursive
```

The first script tests the launcher, immutable artifact checks, shared lock, cloud-window refusal, output filtering, promotion receipt, and executor bootstrap. The second tests this handoff against the actual Terraform outputs and the committed output allowlist. Both are offline checks; neither calls AWS, GitHub, CodeBuild, or Terraform apply.

## External setup evidence

GitHub workflow YAML cannot configure repository protection. Before an external launch, the repository owner records the following evidence in the R4 evidence manifest or a durable release attachment:

| Control | Required evidence | Reject when missing |
| --- | --- | --- |
| Repository visibility and owner | Confirmed repository URL and owner/visibility-compatible protection capability | A public URL or assumed owner is not evidence. |
| `develop` protection | Screenshot or API record showing pull requests, reviews, and required `local-contracts` checks | Direct pushes or an unreviewed merge cannot stage a deployment. |
| `main` protection | Screenshot or API record showing pull requests, reviews, required checks, and restricted bypass | Direct production pushes or unrestricted bypass cannot promote a release. |
| `staging` environment | Environment rule permitting only `develop`, with its exact launcher role/configuration | A pull-request job cannot receive a deployment identity. |
| `production` environment | Environment rule permitting only `main`, with its exact launcher role/configuration | A branch other than `main` cannot receive the production identity. |
| OIDC trust | Reviewed IAM trust policy with `aud=sts.amazonaws.com` and the exact `repo:OWNER/REPOSITORY:environment:ENVIRONMENT` subject | `pull_request`, wildcard repository, or wildcard environment subjects are rejected. |
| Cloud window | Current JSON evidence accepted by `scripts/check-cloud-window.ps1` | Closed, stale, over-allowance, or incomplete evidence prevents launcher execution. |

Keep the concrete repository owner, account ID, ARNs, bucket names, evidence secret values, and deployment URLs outside this repository until they are confirmed. Do not make a repository public to work around unavailable protection features.

## Output artifact contract

`scripts/export-outputs.ps1` publishes a JSON document with this fixed envelope:

```json
{
  "schemaVersion": 1,
  "environment": "foundation | staging | production",
  "sourceCommit": "40-lowercase-hex commit",
  "outputs": { "allowlistedField": "terraform output value" }
}
```

Only the mappings in [`contracts/outputs-allowlist.json`](../contracts/outputs-allowlist.json) may appear, and each scope must contain its complete schema-v1 field set. The exporter fails before publication when any allowlisted Terraform output is missing or null; the consumer repeats the same complete foundation-schema check after its named object version and SHA-256 are verified. The currently implemented Kubernetes owner scopes are:

| Scope | Published fields | Consumer boundary |
| --- | --- | --- |
| `foundation` | `vpcId`, `privateSubnetIds`, `databaseSubnetIds`, `functionSecurityGroupId`, `clusterName`, `clusterOidcProviderArn`, `vpcLinkId`, `backendListenerArns`, `codeBuildProjects` | Platform, Functions, and private deployment executors. |
| `environment` | `apiId`, `backendIntegrationId`, `healthIntegrationId`, `targetGroupArn`, `listenerArn`, `namespace` | Functions, the stable application Service/target binding, and rollout checks. |

The exporter rejects field names or Terraform output names containing `secret`, `password`, `credential`, `token`, `state`, or `master`. It does not publish raw Terraform state, database credentials, cloud-window evidence, private key material, or secret values. `alertTopicArn` is not part of the I1–I7 Kubernetes output artifact; monitoring outputs are added only with the R2 owner implementation and its reviewed contract.

After a reviewed foundation apply, its distinct foundation execution identity receives only the exported `foundation_output_publisher_policy_arn`. It runs `scripts/publish-foundation-outputs.ps1`, which exports the allowlist, writes it to `releases/k8s/foundation/outputs/{sourceCommit}.json`, and records the returned S3 `VersionId` and SHA-256 in a foundation-output receipt. Kubernetes staging/production launchers receive read-only access to that prefix. Their protected GitHub environment stores the reviewed receipt JSON as `FOUNDATION_OUTPUT_RECEIPT_JSON`; `scripts/resolve-foundation-outputs.ps1` retrieves the exact named version, verifies the receipt digest/schema/environment/source commit, and is the only path that adds `foundation_outputs` to the uploaded platform tfvars. The base tfvars file is rejected if it already supplies `foundation_outputs`.

Consumers must validate `schemaVersion`, `environment`, `sourceCommit`, and their expected fields before use. An output document identifies the producing source commit; it is not a successful deployment attestation. R4 preserves the foundation receipt's bucket, key, `VersionId`, SHA-256, source commit, and the resulting platform tfvars SHA-256 with each platform deployment record.

## Executor provider boundaries

The eight CodeBuild roles use a separate reviewed profile for each repository and environment: `kubernetes-{staging,production}`, `database-{staging,production}`, `functions-{staging,production}`, and `application-{staging,production}`. Each profile is appended to the role's already scoped artifact, logs, deployer-image, and Terraform-state permissions. Database roles manage only their environment RDS, subnet-group, and Secrets Manager names; Functions roles manage only their environment Lambda, queue, table, log, and IAM names; Application roles only discover the reviewed EKS cluster and environment image; Kubernetes roles alone manage the shared platform boundary and reviewed node groups. No profile receives another repository's provider namespace.

Foundation also owns the dedicated Lambda and RDS security groups. Lambda egress is limited to TCP 443 for AWS APIs and TCP 5432 to the RDS group. The RDS group admits TCP 5432 only from the Lambda group. The versioned foundation artifact publishes `functionSecurityGroupId`; Functions roots require that exact value alongside the approved private subnets.

## Ordered release handoff

The order below is a required dry-run and R4 checklist. Separate Terraform state keys only isolate state; cross-root shared changes also use `scripts/deployment-lock.ps1` with the existing state bucket. The lock uses conditional creation, carries an owner token, rejects concurrent acquisition, and never allows a non-owner release.

1. **Human bootstrap:** validate the dedicated MFA human identity and approved input file, then create/migrate protected state and OIDC only during an authorized cloud window.
2. **Foundation and executors:** provision the VPC, private EKS capacity, shared ALB/VPC link, state-scoped CodeBuild executors, and immutable deployer-image binding.
3. **Platform and database:** create each environment platform boundary and private RDS environment after verified foundation output artifacts are available.
4. **Application data boundary:** run the APP migration/role/view bootstrap job with its distinct credentials; verify schema, views, and least-privilege grants before application writers start.
5. **Serverless boundary:** deploy function artifacts and their environment resources only after their lookup/view and platform references pass validation.
6. **Service and application rollout:** apply the stable `oficina-app` Service and target binding, then run the reviewed migration/rollout sequence. An empty target group is valid before healthy pods register; no application repository may rebind the target group.
7. **Monitoring bindings:** install the R2 monitoring resources and bind dashboards/alarms only after their resource references and telemetry limits are reviewed.
8. **Acceptance record:** R4 records one result for each repository/environment pair: K8S staging/production, DB staging/production, Functions staging/production, and APP staging/production. A planned, skipped, or failed run remains `NOT_RUN` or `FAIL`; it must never be represented as a successful deployment.

For each real record, preserve the source commit, artifact digest, release-manifest digest/version, Terraform plan reference, CodeBuild build ID/status, outputs artifact version, environment, timestamp, expected/observed result, and durable evidence link. Production must additionally carry the exact verified staging manifest SHA-256, artifact SHA-256, promotion receipt SHA-256, S3 key, and S3 VersionId.

## Promotion and stop conditions

`develop` can launch only the staging workflow. `main` can launch only the production workflow. Both release jobs serialize their own environment with `cancel-in-progress: false`. A staging success writes an immutable promotion receipt only after CodeBuild returns `SUCCEEDED`. Production verifies the named receipt and named staging manifest S3 versions, their SHA-256 values, the successful build identity, and the exact staged artifact before creating its own manifest.

Stop the release and retain the failed evidence if any condition is false: local contract checks; reviewed input identity; cloud-window check; plan review; artifact/manifest/tfvars digest; exact executor project/prefix; required production receipt; migration success; readiness/target registration; or capacity/telemetry acceptance. Do not run destructive rollback, `terraform destroy`, broad S3 lock deletion, a public visibility change, or a release retry that changes the reviewed artifact without a new staging pass.

Use [deployment-sequence.md](deployment-sequence.md) for launcher/bootstrap detail, [bootstrap.md](bootstrap.md) for protected-state setup, and [platform-workloads.md](platform-workloads.md) for service, ingress, and namespace ownership.
