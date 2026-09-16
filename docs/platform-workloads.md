# Environment platform workloads

`k8s/platform` renders the staging and production platform workload package. It owns two isolated namespaces, application service account and release RBAC, secret-store references, the fixed `oficina-app` Service, target-group binding, workload capacity policy and network policies.

The renderer requires immutable image and infrastructure-reference inputs. It refuses unresolved placeholders, a mutable image, non-role principals and malformed ARNs. No secret value is accepted or written: `APP_SECRET_ARN` is only a Secrets Manager reference used by the CSI provider.

```powershell
./scripts/render-platform.ps1 -Environment staging `
  -Image 'ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/oficina-app@sha256:DIGEST' `
  -TargetGroupArn 'arn:aws:elasticloadbalancing:us-east-1:ACCOUNT:targetgroup/NAME/ID' `
  -AppIrsaRoleArn 'arn:aws:iam::ACCOUNT:role/oficina-app-staging' `
  -DeployerPrincipalArn 'arn:aws:iam::ACCOUNT:role/oficina-k8s-staging-deploy' `
  -DbHost 'DATABASE_ENDPOINT' -DbCidr 'DATABASE_SUBNET_CIDR' -VpcCidr 'VPC_CIDR' `
  -AppSecretArn 'arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:oficina/staging/app-EXAMPLE' `
  -OutputDirectory .rendered
```

The foundation creates the shared internal ALB, VPC link and fixed 503 listeners. The platform Terraform module creates the per-environment IP target group, one catch-all forwarding listener rule, HTTP API/integrations and exact EKS access entry. Environment roots receive those fields as an allowlisted `foundation_outputs` contract, not independent manually copied IDs. Terraform never attaches individual targets; the pinned AWS Load Balancer Controller does that through `TargetGroupBinding` after the stable Service exists.

Every namespace begins with ingress/egress deny. App ingress is limited to the two ALB source subnet CIDRs, same-environment app pods and metrics-server. It cannot admit arbitrary VPC pod traffic, so staging app pods cannot reach production app pods on port 8080. Egress permits CoreDNS, the supplied database CIDR on TCP 5432 and HTTPS for approved AWS services. Standard Kubernetes `NetworkPolicy` cannot identify AWS services by FQDN, so HTTPS egress remains additionally bounded by environment IRSA, private-subnet routing and AWS security groups. `namespace-isolation.ps1 -Run` uses the deployed `oficina-staging`/`oficina-production` policies and an app-labeled probe, and refuses a non-Cilium cluster. R4 must verify the result using live endpoints; this document does not claim FQDN-level filtering.

Normal releases use zero surge and one unavailable pod. The first schema-writer cutover is a separately controlled migration sequence that drains old writers before a temporary `Recreate` strategy; it is not an ordinary rollout setting. Staging HPA is 1–2 replicas, production is 2–4, both at 60% CPU. Production has `minAvailable: 1`. Across both HPA maxima, application requests are 1.50 vCPU/4.50 GiB; together with the existing 2.25 vCPU/6 GiB platform reserve this is 3.75 vCPU/10.50 GiB under the two-worker physical hypothesis. `tests/workload-capacity-tests.ps1` enforces that static envelope. R4 must still measure allocatable node, CNI and DaemonSet capacity before cloud apply.
