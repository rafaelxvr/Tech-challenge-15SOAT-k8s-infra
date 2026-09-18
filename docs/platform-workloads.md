# Environment platform workloads

For foundation-owned staging runtime IAM, see the optional
[staging APP IRSA contract](staging-app-irsa.md). Production role inputs remain
externally reviewed and unchanged.

`k8s/platform` renders the staging and production platform workload package. It owns two isolated namespaces, application service account and release RBAC, secret-store references, the fixed `oficina-app` Service, target-group binding, workload capacity policy and network policies.

The renderer requires an immutable us-east-1 ECR image and infrastructure-reference inputs. It refuses unresolved placeholders, mutable images, unsafe substitutions, cross-account principals and cross-environment runtime secret references. No secret value is accepted or written: the app, authorizer-trust and ingest inputs are exact Secrets Manager references used by the CSI provider. The ECR account must match the reviewed workload account.

Both APP overlays explicitly run with numeric UID/GID `10001`, matching the APP
image, and use volume group `10001` for mounted-volume access. Containers inherit
the pod identity while retaining nonroot enforcement, `RuntimeDefault` seccomp,
no privilege escalation, a read-only root filesystem and all capabilities dropped.
The staging bootstrap bundle preserves the same security context. Environment
namespaces, secret references, RBAC and production capacity remain isolated.

The foundation-owned deployment executor policy additionally permits only the
`oficina-app` staging executor to call `ecr:DescribeImages` and
`ecr:BatchGetImage` on the exact same-account `${name}-app` repository
(`oficina-phase3-app` for this platform). This supplements the existing
environment-prefixed repository scope for release digest inspection. It adds no
image push, repository mutation or production permission. Activating the policy
requires a separately reviewed foundation plan/apply; merging this source does
not update the live CodeBuild role. Regenerate and review the platform/workload
bundle digests before deploying the numeric runtime identity.

```powershell
./scripts/render-platform.ps1 -Environment staging `
  -Image 'ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/oficina-app@sha256:DIGEST' `
  -AppIrsaRoleArn 'arn:aws:iam::ACCOUNT:role/oficina-app-staging' `
  -DeployerPrincipalArn 'arn:aws:iam::ACCOUNT:role/oficina-k8s-staging-deploy' `
  -PlatformBindingPrincipalArn 'arn:aws:iam::ACCOUNT:role/oficina-platform-binding' `
  -DbHost 'DATABASE_ENDPOINT' -DbCidr 'DATABASE_SUBNET_CIDR' `
  -AlbSubnetCidrOne 'ALB_SUBNET_ONE_CIDR' -AlbSubnetCidrTwo 'ALB_SUBNET_TWO_CIDR' `
  -AppSecretArn 'arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:oficina/staging/app-AbCdEf' `
  -AuthorizerTrustSecretArn 'arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:oficina/staging/authorizer-trust-AbCdEf' `
  -NewRelicIngestSecretArn 'arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:oficina/staging/newrelic-ingest-AbCdEf' `
  -NewRelicAccountId 'REVIEWED_ACCOUNT_ID' `
  -OutputDirectory .rendered
```

Replace illustrative ACCOUNT/DIGEST/AbCdEf values with reviewed outputs (the AWS secret ARN suffix is six alphanumeric characters). Rendering is offline and never applies resources.

## I6 application runtime contract

Before rollout, APP release orchestration must install a reviewed ConfigMap named `oficina-runtime-public-staging` or `oficina-runtime-public-production` in the corresponding namespace. This package deliberately references existing configuration rather than accepting secret values or inventing issuer/audience values. Missing configuration fails pod startup. The ConfigMap contains:

The handoff can be rendered for review without cluster or AWS access:

```powershell
./scripts/render-runtime-public-configmap.ps1 -Environment staging `
  -CustomerPublicKeysFile .\reviewed\customer-public-keys.yaml `
  -StaffKeyId 'staff-YYYY-MM' `
  -NotificationQueueUrl 'https://sqs.us-east-1.amazonaws.com/ACCOUNT/oficina-phase3-staging-notifications.fifo' `
  -HistoryZone 'UTC' -RdsCaFile .\reviewed\us-east-1-bundle.pem `
  -ExpectedRdsCaSha256 'REVIEWED_BOOTSTRAP_CA_SHA256' `
  -OutputDirectory .rendered
```

The renderer accepts only reviewed public key and CA files plus explicit non-secret environment values. It emits the ConfigMap manifest and never applies it; APP release orchestration remains responsible for installing the reviewed output after migration readiness is proven.

| Key | Required reviewed content |
| --- | --- |
| `customer-public-keys.yaml` | Only `security.jwt.customer.public-keys`: trusted kid to RSA X.509 SubjectPublicKeyInfo PEM mapping. Convert reviewed FUN public JWK output to SPKI PEM before publishing; a JWK is not directly accepted by APP. No private key, staff HMAC or other Spring override is allowed. |
| `staff-issuer`, `staff-audience`, `staff-key-id` | Exact environment-specific staff trust settings shared with the authorizer. |
| `customer-issuer`, `customer-audience` | Exact environment-specific customer trust settings shared with the signer/authorizer. |
| `notification-queue-url`, `history-zone` | That environment's reviewed FIFO queue URL; proven legacy timestamp compatibility zone (UTC only for a fresh synthetic installation). |
| `rds-ca.pem` | Regional public RDS CA bundle, pinned by `ExpectedRdsCaSha256` to the bootstrap review's CA hash. ASCII PEM bytes, including CRLF/LF and trailing newlines, are preserved in the mounted ConfigMap value. BOM-encoded files and mismatched hashes are rejected before output. |

Use the independently reviewed bootstrap CA hash as the renderer input; do not
derive a new accepted hash from a divergent candidate file. The renderer emits
the CA as a JSON-quoted YAML scalar so parsing cannot normalize its line endings
or remove its final newline. Re-render and review both artifact hashes after a
renderer change. Existing published artifacts remain immutable. The platform
renderer likewise quotes numeric New Relic account IDs explicitly so Kubernetes
receives a string-valued environment variable.

Install new customer public keys before activating the corresponding signer kid and retain old keys for the reviewed overlap. The CSI provider projects only `STAFF_HMAC_SECRET` from the existing approved authorizer-trust bundle into the separate `oficina-staff-jwt` Kubernetes Secret. Customer private signing material is never referenced. This reuses the approved secret inventory; it creates no AWS secret. The APP runtime credential secret retains its existing `username`/`password` JSON contract; never supply the master or migration credential ARN.

The reviewed APP IRSA role must trust the exact environment namespace/service account and already permit reads of only the three referenced runtime secrets plus `sqs:SendMessage` to its environment queue. This source change does not expand Terraform IAM permissions: supplying that role is a deployment prerequisite. Public configuration contains no credentials. The database URL uses the approved `oficina` database with `verify-full` and an explicit mounted CA path.

Cloud pods disable Flyway and set Hibernate DDL to `validate`. Migration/bootstrap Jobs and their distinct credentials remain APP-owned and must succeed before this package is released. The first writer cutover drains old writers before migration and uses APP-controlled Recreate sequencing; this ordinary compatible-release template retains zero-surge RollingUpdate. Do not grant migration credentials to these pods or roll back to an incompatible writer. No migration Job or cloud cutover is performed by the renderer.

The stable Service remains `oficina-app:8080`; only the platform binding principal attaches its environment target group. The first K8S apply publishes only the base API, health/public routes and stage. FUN receives the K8S API handoff and owns the REQUEST authorizer plus the two public CPF routes. After FUN returns its reviewed authorizer ID, a second K8S apply binds protected APP routes to that ID. The route matrix remains byte-identical, including explicit scopes/compatibility aliases and no retired email mutation; rollout must not create duplicate gateway routes or weaken APP resource authorization.

Offline checks: `pwsh -File tests/application-rollout-tests.ps1`, `pwsh -File tests/platform-manifests-tests.ps1`, and `pwsh -File tests/workload-capacity-tests.ps1`. These render both overlays and check immutable images, requests/limits, probes, trust separation, migration restrictions, HPA/PDB and invalid input rejection. A disposable Kind cutover, live IRSA/CSI access, key rotation and actual allocatable capacity remain integration acceptance work; local rendering does not prove them.

The foundation creates the shared internal ALB, VPC link and fixed 503 listeners. The platform Terraform module creates the per-environment IP target group, one catch-all forwarding listener rule, HTTP API/integrations and exact EKS access entry. Environment roots receive those fields as an allowlisted `foundation_outputs` contract, not independent manually copied IDs. Terraform never attaches individual targets; the pinned AWS Load Balancer Controller does that through `TargetGroupBinding` after the stable Service exists.

## Gateway and functions contract

The platform vendors the byte-identical APP `phase3-v2/routes.json` route matrix
(SHA-256 `7e1cff5e6c57174af792bb44b33e63572f885698ab5ef2f24d5aeebda883c1a8`).
It creates no catch-all route: `ALLOW` entries are the only routes published, so
the retired email mutation is absent and the v2 ADMIN report is protected.

Each environment consumes only the `functionArns` allowlisted output from
`oficina-functions`: `authorizer`, `challenge`, and `verification`. The request
authorizer is payload v2/simple-response with a zero result TTL and no configured
identity sources. CPF challenge and verification are the two public Lambda proxy
routes; all other protected APP routes use the authorizer. Lambda permissions are
scoped to the environment API's authorizer or exact method/path. This repository
does not configure function runtime secrets, customer private keys, database
credentials, VPC attachment or Function URLs; those remain in the functions
state and runtime role.

The API reaches APP only through the existing VPC Link and internal ALB. Access
logs retain only request ID, route template, status, bounded latency fields and
safe authorizer category for one day. CORS accepts only explicitly injected HTTPS
origins, never `*`, and does not allow credentials. Initial stage throttling is
one request/second with a burst of two; R4 records the live behavior before any
adjustment.

The application-release role cannot read, create or mutate `TargetGroupBinding`. A separate reviewed `platform_binding_principal_arn` is the only principal permitted to apply `k8s/platform/binding/target-group-binding.yaml`. Render it separately after the stable Service exists; the renderers accept only the `oficina-phase3-<environment>-app` target-group ARN produced by the fixed-name platform Terraform module.

Before either binding is applied, a trusted platform administrator renders and applies `k8s/platform/admission/target-group-binding-admission.yaml`. This is Kubernetes 1.35's native `ValidatingAdmissionPolicy`, so it adds no webhook deployment, service account, RBAC or controller capacity. It fails closed for every `TargetGroupBinding` create/update unless the object is named `oficina-app`, has the two trusted managed-by labels, and pairs `oficina-staging` or `oficina-production` with its literal reviewed target-group ARN. It therefore blocks a direct `kubectl patch` to the other environment even for the name-limited platform-binding identity.

```powershell
./scripts/render-target-group-binding-admission.ps1 `
  -StagingTargetGroupArn 'arn:aws:elasticloadbalancing:us-east-1:ACCOUNT:targetgroup/oficina-phase3-staging-app/TARGET_GROUP_ID' `
  -ProductionTargetGroupArn 'arn:aws:elasticloadbalancing:us-east-1:ACCOUNT:targetgroup/oficina-phase3-production-app/TARGET_GROUP_ID' `
  -OutputDirectory .rendered
kubectl apply -f .rendered/target-group-binding-admission.yaml
```

```powershell
./scripts/render-target-group-binding.ps1 -Environment staging `
  -TargetGroupArn 'arn:aws:elasticloadbalancing:us-east-1:ACCOUNT:targetgroup/oficina-phase3-staging-app/TARGET_GROUP_ID' `
  -OutputDirectory .rendered
```

Kubernetes RBAC cannot constrain `create` by resource name. The platform-binding identity therefore has an intentionally unrestricted TargetGroupBinding create rule, while get/patch/update remain name-limited to `oficina-app`; the fail-closed admission policy is the required safety boundary for create. Its only diagnostic exception permits a unique `oficina-app-admission-probe-*` name when `request.dryRun` is true, so no persisted object can use that name. For cloud acceptance, run `tests/target-group-binding-admission-tests.ps1 -Run` using that authenticated context after the policy and reviewed staging binding exist. It separately uses a unique server-side dry-run CREATE probe, then an existing `oficina-staging/oficina-app` binding for dry-run UPDATE. Each path accepts the exact staging target and denies a direct staging-to-production retarget. The test does not make an AWS API call or mutate the binding.

Every namespace begins with ingress/egress deny. App ingress is limited to the two ALB source subnet CIDRs, same-environment app pods and metrics-server. It cannot admit arbitrary VPC pod traffic, so staging app pods cannot reach production app pods on port 8080. Egress permits CoreDNS, the supplied database CIDR on TCP 5432 and HTTPS for approved AWS services. Standard Kubernetes `NetworkPolicy` cannot identify AWS services by FQDN, so HTTPS egress remains additionally bounded by environment IRSA, private-subnet routing and AWS security groups. `namespace-isolation.ps1 -Run` uses the deployed `oficina-staging`/`oficina-production` policies and an app-labeled probe, and refuses a non-Cilium cluster. R4 must verify the result using live endpoints; this document does not claim FQDN-level filtering.

Normal releases use zero surge and one unavailable pod. The first schema-writer cutover is a separately controlled migration sequence that drains old writers before a temporary `Recreate` strategy; it is not an ordinary rollout setting. Staging HPA is 1–2 replicas, production is 2–4, both at 60% CPU. Production has `minAvailable: 1`. Across both HPA maxima, application requests are 1.50 vCPU/4.50 GiB; together with the existing 2.25 vCPU/6 GiB platform reserve this is 3.75 vCPU/10.50 GiB under the two-worker physical hypothesis. `tests/workload-capacity-tests.ps1` enforces that static envelope. R4 must still measure allocatable node, CNI and DaemonSet capacity before cloud apply.
