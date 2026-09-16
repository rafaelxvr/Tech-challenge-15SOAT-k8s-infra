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

The platform Terraform module creates only the per-environment listener, IP target group, HTTP API/integrations, security-group rules and an exact EKS access entry. The shared internal ALB and VPC link are required foundation inputs. Terraform never attaches individual targets; the pinned AWS Load Balancer Controller does that through `TargetGroupBinding` after the stable Service exists.

Every namespace begins with ingress/egress deny. The app policy permits DNS, its supplied database CIDR on TCP 5432 and HTTPS for approved AWS services. Standard Kubernetes `NetworkPolicy` cannot identify AWS services by FQDN, so HTTPS egress remains additionally bounded by the private-subnet route and AWS security groups. R4 must verify effective enforcement using the VPC CNI network-policy mode and live endpoints; this document does not claim FQDN-level filtering.

Normal releases use zero surge and one unavailable pod. The first schema-writer cutover is a separately controlled migration sequence that drains old writers before a temporary `Recreate` strategy; it is not an ordinary rollout setting. Staging HPA is 1–2 replicas, production is 2–4, both at 60% CPU. Production has `minAvailable: 1`. Across both HPA maxima, application requests are 1.50 vCPU/4.50 GiB; together with the existing 2.25 vCPU/6 GiB platform reserve this is 3.75 vCPU/10.50 GiB under the two-worker physical hypothesis. `tests/workload-capacity-tests.ps1` enforces that static envelope. R4 must still measure allocatable node, CNI and DaemonSet capacity before cloud apply.
