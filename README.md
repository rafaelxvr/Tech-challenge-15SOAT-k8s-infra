# Oficina Kubernetes infrastructure

This repository owns the Kubernetes/EKS infrastructure boundary for Oficina staging and production. Terraform roots and deployment workflows arrive in Phase 3 task I1; `infra/` is reserved for that versioned infrastructure code.

The environment platform lives in `infra/environments/{staging,production}` and `k8s/platform`. It creates isolated namespaces, fixed internal HTTP API integrations and workload policies while consuming the shared foundation's ALB, VPC link and EKS values. Render manifests without cluster or AWS access:

```powershell
pwsh ./tests/platform-manifests-tests.ps1
```

Remote owner, visibility, protected branches, environment credentials, and deployment targets are release prerequisites and are intentionally unset in this local bootstrap.

The CI/CD contract is documented in [docs/deployment-sequence.md](docs/deployment-sequence.md). The external-protection checklist, output schema, ordered handoff, and R4 evidence boundary are in [docs/release-readiness.md](docs/release-readiness.md). Its local verification has no AWS or GitHub side effects:

```powershell
pwsh ./tests/pipeline-contract.ps1
pwsh ./tests/release-readiness-contract.ps1
```
