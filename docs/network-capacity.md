# Network and fixed capacity record

## Bounded topology

Foundation creates one `10.42.0.0/16` VPC across two reviewed AZs. Each AZ has one public NAT subnet, one private workload/CodeBuild subnet, and one isolated database subnet. There is one EIP and one NAT gateway, located in the first public subnet. Private workloads have no public address. The database route table has no default route. S3 and DynamoDB use gateway endpoints; no interface endpoint is introduced. Other AWS API traffic uses the one NAT only while the study environment is operating.

The EKS control-plane endpoint is private-only. The cluster is EKS 1.35. The deploy-time input locks the AL2023 release and EKS add-on builds after compatibility review; Terraform deliberately rejects an empty or unpinned value rather than inventing a current AMI. VPC CNI is configured with `enableNetworkPolicy=true`, so future Kubernetes NetworkPolicy tests have an enforcing data plane rather than YAML-only evidence.

The cluster has two `m7i-flex.large` x86_64 groups, one per AZ. Each group always has exactly one worker, 20 GiB gp3 root storage, and a serial `MINIMAL` update with `maxUnavailable=1`. This prevents replacement surge capacity from exceeding the observed account vCPU quota. It also means an update temporarily reduces capacity; live update sequencing is tested in R4, never during Terraform planning.

## Capacity calculation

Planning hypothesis: two workers together expose 4 vCPU and 16 GiB physical memory. Kubernetes allocatable values vary with EKS, CNI and DaemonSet reservations, so this is a capacity budget, not a claim of final allocatable measurements.

| Workload allowance | CPU request | Memory request |
| --- | ---: | ---: |
| App steady state (2 pods × 250m/768Mi) | 0.50 | 1.50 GiB |
| App rollout surge (2 pods × 250m/768Mi) | 0.50 | 1.50 GiB |
| Platform, observability and system reserves | 2.25 | 6.00 GiB |
| **Total planning request** | **3.25 vCPU** | **9.00 GiB** |

The 3.25 vCPU/9 GiB total fits within the 4 vCPU/16 GiB physical hypothesis, leaving 0.75 vCPU and 7 GiB before actual kubelet/CNI reservations. Pod ENI availability is not inferred from CPU or memory. R4 must record `kubectl describe node` allocatable resources, VPC CNI pod-ENI limits, system/DaemonSet requests, and a scheduling test under the configured surge. If either actual measurement is lower than this budget, scale settings or requests must be reduced before deployment proceeds.

## Private deployment executors

There are exactly eight short-lived CodeBuild projects: four repository owners × staging and production. Each has a unique IAM role, S3 source prefix, CloudWatch Logs group, private subnet pair and CodeBuild security group. The projects use Linux Small, one active build maximum, S3 source and `privileged_mode=false`; they do not store GitHub credentials or run persistent runners. The reviewed bootstrap/human operation creates foundation before these jobs exist. Later private EKS/RDS work uses these jobs because GitHub-hosted runners cannot reach private endpoints.

The service role uses `ecr:GetAuthorizationToken` with the AWS-required `Resource="*"` exception; layer and image actions remain scoped to the sole platform deployer repository. This is not an IRSA trust subject. The VPC CNI IRSA policy has exact audience and service-account conditions and no wildcard subject.

`images/deployer/Dockerfile` is the platform image definition. It pins the Amazon Linux base digest and PowerShell 7.4.6, Java 17, AWS CLI 2.17.62, Terraform 1.15.8, kubectl 1.35.0 and Helm 3.17.4. The GitHub platform-image workflow builds it, scans it and records its digest. CodeBuild consumes only that ECR digest, not a mutable tag. The ECR policy retains one image; that image counts against the previously approved retained-image allowance.

The VPC CNI role's web-identity trust requires both the EKS OIDC audience `sts.amazonaws.com` and exactly `system:serviceaccount:kube-system:aws-node`. It contains no namespace or service-account wildcard.
