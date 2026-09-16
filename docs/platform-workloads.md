# Environment platform workloads

`k8s/platform` renders the staging and production platform workload package. It owns two isolated namespaces, application service account and release RBAC, secret-store references, the fixed `oficina-app` Service, target-group binding, workload capacity policy and network policies.

The renderer requires immutable image and infrastructure-reference inputs. It refuses unresolved placeholders, a mutable image, non-role principals and malformed ARNs. No secret value is accepted or written: `APP_SECRET_ARN` is only a Secrets Manager reference used by the CSI provider.

```powershell
./scripts/render-platform.ps1 -Environment staging `
  -Image 'ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/oficina-app@sha256:DIGEST' `
  -AppIrsaRoleArn 'arn:aws:iam::ACCOUNT:role/oficina-app-staging' `
  -DeployerPrincipalArn 'arn:aws:iam::ACCOUNT:role/oficina-k8s-staging-deploy' `
  -PlatformBindingPrincipalArn 'arn:aws:iam::ACCOUNT:role/oficina-platform-binding' `
  -DbHost 'DATABASE_ENDPOINT' -DbCidr 'DATABASE_SUBNET_CIDR' `
  -AlbSubnetCidrOne 'ALB_SUBNET_ONE_CIDR' -AlbSubnetCidrTwo 'ALB_SUBNET_TWO_CIDR' `
  -AppSecretArn 'arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:oficina/staging/app-EXAMPLE' `
  -OutputDirectory .rendered
```

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
