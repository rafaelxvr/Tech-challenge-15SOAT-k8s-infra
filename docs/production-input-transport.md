# APP and Functions production input transport

The deployment-executor module now accepts an optional `production_input_bindings` map. Its empty default rejects APP/FUN production builds with `PRODUCTION_TRANSPORT_DISABLED` before the first AWS command. This source change does not configure the map in the foundation root, enable any launcher, apply Terraform, create credentials or change GitHub/OIDC settings. Existing staging paths and parameters remain unchanged.

Each map key must name an existing APP or Functions **production** deployment. A reviewed entry contains:

| Field | Contract |
| --- | --- |
| `enabled` | Boolean, defaults false. Explicit Terraform-reviewed selection of production transport. |
| `launcher_enabled` | Boolean, defaults false. Execution additionally requires the existing deployment's `deployment_mode = "apply"`; either gate alone leaves the adapter in preflight. |
| `role_arn` | Exact same-account production launcher role asserted by the reviewed APP/FUN input document. This binds context; the transport neither assumes the role nor proves GitHub protection settings. |
| `source_commit` | Exact 40-character lowercase SHA, also required in the source/release/promotion input document. |
| `review_object_key` | `releases/app/production/reviews/<commit>/inputs.zip` or `releases/functions/production/reviews/<commit>/inputs.zip`. |
| `review_version_id` | Immutable, nonempty S3 object version; `null` is rejected. |
| `review_sha256` / `inputs_sha256` | Independently reviewed hashes of the ZIP bytes and its root `production-inputs.json`. |

The map is Terraform-owned, rendered into the inline CodeBuild buildspec, and cannot be enabled by StartBuild environment overrides. The bucket, account, region, project, source prefix, state/tfvars paths, deployer image and cluster context also come from the module. No new IAM access to staging artifacts is granted: promotion evidence must be copied into the reviewed production archive after independent review, with its original content/hash retained.

## Public archive layout and adapter boundary

Place `production-inputs.json` at the ZIP root and include every file it references using its existing relative `path` / `sha256` fields. Both owners require the exact source archive, production release manifest, production Terraform variables, production cloud-window evidence and successful same-commit staging promotion receipt. APP additionally requires platform inputs and the staging release manifest. Include no secret values, state or credentials. FUN's newer staging receipt must bind the immutable Lambda JAR/version/hash and deployer digest; a legacy source-only receipt remains insufficient. APP's source adapter requires the promoted image/bootstrap/migration digests and an existing Compatible V8 workload.

The independently downloaded source, release manifest and tfvars must match their counterparts in this archive. The source stays at `releases/<app|functions>/production/bundle.zip`; release/config keys remain `manifests/<commit>.json` and `config/<commit>.tfvars.json` under the same production prefix. Canonical state is `<app|functions>/production.tfstate` with its `.tflock`, and the trusted tfvars path is `/tmp/oficina/<app|functions>_production.tfvars.json`.

The Terraform-owned [transport script](../infra/modules/deployment-executor/production-input-transport.ps1) downloads the exact version, checks both hashes, rejects traversal/symlink/duplicate/oversized archive entries, verifies all public file references, and checks source/project/role/account/environment bindings before invoking any source script. Source extraction uses the same bounded ZIP checks. The public review may include a duplicate copy of the source ZIP so its existing relative reference is preserved; its hash must equal the independently downloaded source.

`scripts/deploy.ps1` receives `ProductionEnabled`, `ProtectedEnvironment`, `ProductionInputsFile`, `ExpectedProductionInputsSha256`, `ProductionRoleArn`, `EventName=push` and `BranchRef=refs/heads/main`, plus its existing source/deployer/backend arguments. APP receives `ProductionRuntimeEnabled`, `SourceArchiveFile`, `SourceKey` and `StateBucket`; FUN receives `ProductionLauncherEnabled`, `ExpectedTerraformVariablesSha256`, `StateBucket` and `SharedFoundationMutation`. First, both run with `-DryRun`. A failed preflight stops transport; apply is forwarded only when both Terraform-owned gates select execution. Only explicitly executing APP configures the exact reviewed EKS cluster context after successful preflight.

The source adapters validate the same-commit staging receipt and image/JAR bindings, enforce the production cost window and own the existing `deployment-locks/shared-foundation.json` lock. FUN's existing lock policy is retained. APP production receives only the exact shared lock object's read/delete and conditional `PutObject` when its transport entry is explicitly enabled; no broader state/prefix, secret, ECR or Kubernetes permissions are added. APP staging's permissions are unchanged. A successful transport/preflight is not deployment or health acceptance.

## Local evidence and unresolved activation

RED: the added default-disabled assertion failed against the previous buildspec (four existing runs passed, one new run failed). GREEN: all 17 mocked executor Terraform runs and 58 mocked transport assertions pass. The existing rendered staging bootstrap harness also passes. These tests use synthetic metadata and mocked AWS/source-adapter calls; they do not authenticate receipts, contact AWS or apply infrastructure.

Run `terraform -chdir=infra/modules/deployment-executor fmt -check -recursive`, `validate`, `test`, `pwsh -NoProfile -File tests/production-input-transport-tests.ps1`, and `tests/pipeline-contract.ps1`. The pipeline now includes the transport assertions.

Activation still requires a separate review to supply/wire the map from the owning foundation configuration, publish immutable public review artifacts, verify actual protected-main provenance and launcher/executor identity, and arrange production launch orchestration (APP/FUN remote `start-deploy.ps1` remains separately disabled). Existing production workload/IRSA/RBAC, bootstrap secret permissions, FUN ownership handoff, exact runtime artifact provenance and production billing/window authorization remain external prerequisites. This change does not widen those permissions or establish runtime readiness, live observability, promotion receipts or R4 acceptance.
