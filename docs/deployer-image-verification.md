# Fresh staging deployer image: dependency and evidence contract

The deployer Dockerfile now requires five independently reviewed SHA256 build inputs. It validates their format before package/download operations and checks each downloaded file before installation, extraction or executable permission changes. Missing inputs, invalid lowercase SHA256 syntax, missing files and changed bytes stop the build. The image build context must be the repository root because the Dockerfile copies `images/deployer/verify-sha256.sh` from that context.

No image build/push, image upload, registry change or CodeBuild update is performed by this source change. Existing image digests are unaffected. CI executes only `tests/deployer-dependencies-tests.ps1`, using temporary fixture bytes and a local POSIX shell; it does not download the tools or run Docker.

## Explicit reviewed verification inputs

| Build argument | Version default | Bytes whose SHA256 must be reviewed |
| --- | --- | --- |
| `POWERSHELL_SHA256` | `POWERSHELL_VERSION=7.4.6` | `powershell-7.4.6-1.rh.x86_64.rpm` |
| `AWS_CLI_SHA256` | `AWS_CLI_VERSION=2.36.42` | `awscli-exe-linux-x86_64-2.36.42.zip` |
| `TERRAFORM_SHA256` | `TERRAFORM_VERSION=1.15.8` | `terraform_1.15.8_linux_amd64.zip` |
| `KUBECTL_SHA256` | `KUBECTL_VERSION=v1.35.0` | Linux/amd64 `kubectl` for v1.35.0 |
| `HELM_SHA256` | `HELM_VERSION=v3.17.4` | `helm-v3.17.4-linux-amd64.tar.gz` |

There are deliberately no checksum defaults or invented ready-to-use values. The future build review must obtain the exact tool hashes through trusted release metadata and, where available, verify publisher signatures with reviewed key identities. Record the source URL, version, verification method/key fingerprint, checksum and review reference in a hashed build-input document. A version override requires a corresponding reviewed checksum and input-document update. Do not calculate an expected checksum from the same newly downloaded file inside the build: that would not establish trusted expected bytes.

The Dockerfile enforces byte equality against the supplied inputs; it does not authenticate the reviewer, publisher or origin of those inputs. A hash of an untrusted file is not a trusted checksum. The five real values and their verification evidence remain pending.

## Future workflow design (not installed or enabled)

The current CI workflow checks the dependency contract only. A separate reviewed platform-image workflow is still needed; the earlier claim that such a build/publish workflow already existed was inaccurate. Its proposed boundaries are:

1. **Reviewed source and inputs:** run from an approved immutable repository commit in a clean checkout. Bind the Dockerfile and checksum-helper hashes, Linux/amd64 platform, pinned Amazon Linux base, all version/checksum arguments, dependency-review document and package policy. Capture the workflow commit, protected environment approval and invocation URL. No credentials or secret values belong in these artifacts.
2. **Builder identity:** pin the build tooling/actions and BuildKit image by digest. Record the actual runner/workflow identity, Buildx/BuildKit versions and immutable builder reference. Configure the chosen attestation producer to emit a nonempty builder identity; verify its signer/issuer and source binding. Do not rewrite an unsigned attestation to fill an empty builder ID. The exact builder image, producer and signing/verification policy require separate review.
3. **Build and evidence:** only a separately authorized run may build/publish a unique immutable tag. Explicitly request SBOM and maximum provenance from the chosen tooling and retain their content hashes, the build log, exact input manifest and RPM inventory. Digest pinning and SBOM/provenance generation do not by themselves prove authenticity or reproducibility. Link the provenance subject to the Linux/amd64 runtime digest; record the OCI index digest separately if one is produced.
4. **Scan disposition:** bind the completed scan report to that exact runtime digest. Retain scan timestamp, severity counts, policy identifier, disposition (`PENDING`, `BLOCKED`, or `ACCEPTED`), reviewer reference and any exception/remediation rationale. Missing/incomplete scans or absent disposition must stop image adoption. The reviewer must set the acceptance policy; this change does not invent a vulnerability threshold or accept existing findings.
5. **Adoption boundary:** emit a signed/verified evidence receipt and keep publication separate from updating CodeBuild. A subsequent reviewed staging-only change must verify ECR existence, exact digest and evidence. Production remains outside this route. No build or evidence flag authorizes a Terraform apply or APP release.

The future receipt must record these fields; angle-bracket values are unresolved design inputs, not a usable release receipt:

```json
{
  "schemaVersion": 1,
  "environment": "staging",
  "sourceCommit": "<full reviewed commit>",
  "dockerfileSha256": "<sha256>",
  "checksumHelperSha256": "<sha256>",
  "buildInputsSha256": "<reviewed versions/checksums/package-policy document hash>",
  "platform": "linux/amd64",
  "baseImage": "amazonlinux@sha256:065856aabb1ddab0441f4024dfbba116cc760286858a53ec74e6a1218af979ee",
  "builder": {
    "identity": "<actual authenticated builder identity>",
    "image": "<builder repository>@sha256:<digest>",
    "workflowCommit": "<full workflow commit>",
    "invocationUrl": "<reviewable run URL>",
    "signatureVerificationReference": "<verified signer/issuer evidence>"
  },
  "image": {
    "indexDigest": "<index digest or null when no index exists>",
    "linuxAmd64Digest": "sha256:<runtime digest>"
  },
  "evidence": {
    "sbomSha256": "<SBOM artifact hash>",
    "provenanceSha256": "<provenance artifact hash>",
    "rpmInventorySha256": "<exact installed RPM inventory hash>",
    "scanReportSha256": "<completed scan report hash>"
  },
  "scan": {
    "subjectDigest": "sha256:<same runtime digest>",
    "completedAtUtc": "<UTC timestamp>",
    "severityCounts": "<actual report counts>",
    "policyReference": "<reviewed acceptance policy>",
    "disposition": "PENDING",
    "reviewReference": "<required before ACCEPTED>",
    "rationale": "<remediation or explicitly accepted residual risk>"
  }
}
```

This is a workflow/receipt design, not an implemented receipt validator or signed provenance system. A future implementation must verify referenced artifact bytes and subject identities, not merely accept this JSON shape.

## Unresolved package versions and remaining inputs

The pinned base and five verified downloads do **not** make the image reproducible: `dnf -y update` still resolves mutable repositories, and `tar`, `gzip`, `unzip`, `java-17-amazon-corretto-headless` and their dependencies are unversioned. Resolve the exact RPM epoch/name/version/release/architecture values and repository snapshot/package hashes, including updated base packages and the providers of curl and sha256sum. Alternatively, explicitly review a policy accepting mutable package resolution while recording the full installed RPM inventory; do not describe that alternative as reproducible.

Still required before any fresh image operation: five trusted download checksums/evidence; RPM resolution or explicit residual-risk policy; reviewed builder image/tooling/identity and attestation verification; approved publication identity/destination/unique tag; completed scan and disposition; and separately authorized image build/publish/adoption. No current digest is substituted, no existing scan findings are accepted, and no external input is generated by these local tests.

Validation: run `pwsh -NoProfile -File tests/deployer-dependencies-tests.ps1`. It checks all five mandatory arguments and download/verify/use ordering, exercises actual SHA256 verification against fixture bytes, and rejects invalid, missing, mismatched and one-byte-corrupted inputs. Git Bash supplies the local POSIX shell on Windows; CI uses `/bin/sh`.
