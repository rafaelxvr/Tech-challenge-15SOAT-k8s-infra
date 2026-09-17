# Network and fixed capacity record

## Bounded topology

Foundation creates one `10.42.0.0/16` VPC across two reviewed AZs. Each AZ has one public NAT subnet, one private workload/CodeBuild subnet, and one isolated database subnet. There is one EIP and one NAT gateway, located in the first public subnet. Private workloads have no public address. The database route table has no default route. S3 and DynamoDB use gateway endpoints; no interface endpoint is introduced. Other AWS API traffic uses the one NAT only while the study environment is operating.

The same foundation creates exactly one internal ALB in the two reviewed ALB source subnets, one VPC link and fixed listener ports 8080/8081. Each listener has a fixed 503 default action. An environment platform root can add only its catch-all listener rule, forwarding to its own readiness-checked IP target group; the AWS Load Balancer Controller registers pod IPs through `TargetGroupBinding`. This makes an empty target group safe during bootstrap and prevents an environment from receiving the other environment's traffic. The environment roots consume the allowlisted foundation-output object, including listener ARNs, VPC link ID and their exact CodeBuild role, instead of separate manually supplied infrastructure IDs.

The EKS control-plane endpoint is private-only. The cluster is EKS 1.35. The deploy-time input locks the AL2023 release and EKS add-on builds after compatibility review; Terraform deliberately rejects an empty or unpinned value rather than inventing a current AMI. VPC CNI is configured with `enableNetworkPolicy=true`, so future Kubernetes NetworkPolicy tests have an enforcing data plane rather than YAML-only evidence.

The cluster has two `m7i-flex.large` x86_64 groups, one per AZ. Each group always has exactly one worker and 20 GiB gp3 root storage. AWS provider 5.100 cannot set EKS `updateStrategy`, so the node-group resource ignores later `release_version` changes. A Terraform apply-bound executor then calls `UpdateNodegroupConfig(maxUnavailable=1, updateStrategy=MINIMAL)`, polls that exact EKS update for at most 120 attempts, and only then calls `UpdateNodegroupVersion`. It processes sorted node-group names one at a time. Unknown states, failed/cancelled states and a poll deadline all fail closed with only state/type/error-code details. Request tokens are deterministic SHA-256-derived values from the cluster, node group and desired configuration or release, so a retry is idempotent. This prevents Terraform from using EKS's default surge strategy before the MINIMAL setting exists, and prevents both groups being replaced together. It also means an update temporarily reduces capacity.

The module's mock test verifies the executor trigger, fixed capacity and supported `max_unavailable=1` setting. Its static contract test verifies the ignored provider release update, bounded polling, deterministic tokens, and the configuration-before-version API sequence. Only the Kubernetes-infrastructure repository's staging and production CodeBuild roles receive the exact cluster/node-group update actions; the other six roles can only describe the cluster. R4's residual cloud validation is limited to recording the returned EKS update strategy/status and confirming the observed one-node-at-a-time behavior; it is not the first enforcement point.

## Capacity calculation

Planning hypothesis: two workers together expose 4 vCPU and 16 GiB physical memory. Kubernetes allocatable values vary with EKS, CNI and DaemonSet reservations, so this is a capacity budget, not a claim of final allocatable measurements.

| Workload allowance | CPU request | Memory request |
| --- | ---: | ---: |
| App HPA maxima (staging 2 + production 4, each 250m/768Mi) | 1.50 | 4.50 GiB |
| AWS Load Balancer Controller + metrics-server | 0.15 | 0.19 GiB |
| CSI driver + AWS provider DaemonSets (two workers each) | 0.20 | 0.25 GiB |
| System and observability reserve after controller requests | 1.90 | 5.56 GiB |
| **Total planning request** | **3.75 vCPU** | **10.50 GiB** |

The 3.75 vCPU/10.50 GiB total fits within the 4 vCPU/16 GiB physical hypothesis, leaving 0.25 vCPU and 5.50 GiB before actual kubelet/CNI reservations. Pod ENI availability is not inferred from CPU or memory. R4 must record `kubectl describe node` allocatable resources, VPC CNI pod-ENI limits, chart-created sidecar/DaemonSet requests and a scheduling test under the configured HPA maxima. If either actual measurement is lower than this budget, scale settings or requests must be reduced before deployment proceeds.

## Private deployment executors

There are exactly eight short-lived CodeBuild projects: four repository owners × staging and production. Terraform rejects any input that does not have exactly one `staging` and one `production` project for every repository. Each project has a unique IAM role, S3 source prefix, CloudWatch Logs group, private subnet pair and CodeBuild security group. The projects use Linux Small, one active build maximum, S3 source and `privileged_mode=false`; they do not store GitHub credentials or run persistent runners. The reviewed bootstrap/human operation creates foundation before these jobs exist. Later private EKS/RDS work uses these jobs because GitHub-hosted runners cannot reach private endpoints.

The service role uses `ecr:GetAuthorizationToken` with the AWS-required `Resource="*"` exception; layer and image actions remain scoped to the sole platform deployer repository. This is not an IRSA trust subject. The VPC CNI IRSA policy has exact audience and service-account conditions and no wildcard subject.

`images/deployer/Dockerfile` is the platform image definition. It pins the Amazon Linux base digest and PowerShell 7.4.6, Java 17, AWS CLI 2.17.62, Terraform 1.15.8, kubectl 1.35.0 and Helm 3.17.4. The GitHub platform-image workflow builds it, scans it and records its digest. CodeBuild consumes only that ECR digest, not a mutable tag. The ECR policy retains one image; that image counts against the previously approved retained-image allowance.

The VPC CNI role's web-identity trust requires both the EKS OIDC audience `sts.amazonaws.com` and exactly `system:serviceaccount:kube-system:aws-node`. It contains no namespace or service-account wildcard.

The AWS Load Balancer Controller Helm release is pinned to chart `1.12.0`, metrics-server to `3.12.2`, Secrets Store CSI Driver to `1.4.8`, and the AWS CSI provider to `0.3.9`. Every installed chart has explicit requests/limits. The controller IRSA trust has the exact `kube-system/aws-load-balancer-controller` subject and its policy can discover network metadata and register/deregister targets only in tagged platform target groups; it cannot create ALBs, listeners or target groups. CSI installation contains references only and never Terraform secret values. R4 must record rendered chart values and actual running resources before treating the planning limits as measured capacity.
