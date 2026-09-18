# Staging APP runtime IRSA

Foundation owns the EKS OIDC provider and runtime IAM roles. The optional
`staging_app_irsa` input creates `oficina-phase3-staging-app` plus its inline
runtime policy. Its default is `null`: existing foundation configurations create
no APP role. Environment executors gain no IAM permissions. This module has no
production switch and does not change production workloads or deploy scripts.

The role trusts only the foundation cluster provider, audience
`sts.amazonaws.com`, and subject
`system:serviceaccount:oficina-staging:oficina-app`, using `StringEquals`.
The role cannot be assumed by another namespace or service account through this
trust policy. No secret, queue, KMS key or key policy is created or discovered.

## Reviewed nonsecret inputs

Add this object to the **foundation** variables only after reviewing all exact
ARNs. This is a synthetic example; its suffixes and account are not live inputs.
The issuer and provider are wired directly from `module.cluster`, never copied
from application variables.

```json
{
  "staging_app_irsa": {
    "runtime_secret_arns": {
      "app": "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/app-AbCd12",
      "authorizer_trust": "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/authorizer-trust-EfGh34",
      "newrelic_ingest": "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/newrelic-ingest-IjKl56"
    },
    "notification_queue_arn": "arn:aws:sqs:us-east-1:123456789012:oficina-phase3-staging-notifications.fifo",
    "secret_kms_key_arns": {},
    "notification_queue_kms_key_arn": null
  }
}
```

The account must match foundation and the region must be `us-east-1`. Secrets
must have the three exact staging names and their complete six-character ARN
suffixes. Queue access is bound to the exact staging notification FIFO ARN.
Production, wildcard, cross-account, migration, master and private signing secret
references are rejected. The known staging queue URL can identify the expected
queue, but review its ARN and encryption metadata before configuring this input.

## Permission boundary

| Resource | Allowed identity-policy actions |
| --- | --- |
| Exactly the three runtime secret ARNs | `secretsmanager:GetSecretValue`, `secretsmanager:DescribeSecret` |
| Exactly the staging notifications FIFO ARN | `sqs:SendMessage` |
| Each explicitly supplied secret KMS key ARN | `kms:Decrypt`, conditioned on exact `SecretARN`, caller account and Secrets Manager via-service |
| Explicitly supplied queue KMS key ARN | `kms:Decrypt`, `kms:GenerateDataKey`, conditioned on exact `aws:sqs:arn`, caller account and SQS via-service |

The two secret actions support the
[AWS Secrets and Configuration Provider](https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_ascp_irsa.html).
IAM authorizes reading the whole secret, not individual JSON fields. CSI projects
the reviewed username/password, staff trust and ingest fields; the trust secret
must not contain customer private signing material or other unauthorized data.
There are no list, write-secret, receive-message, delete-message or IAM actions.

For customer-managed encryption, populate `secret_kms_key_arns` with only the
applicable `app`, `authorizer_trust`, `newrelic_ingest` slots. Supply the queue key
separately when an explicit identity-policy grant is needed. Each value must be
an exact same-account, same-region key ARN, never an alias or wildcard. Empty
inputs add no KMS grants; they do not prove access to encrypted resources.
[Secrets Manager encryption context](https://docs.aws.amazon.com/secretsmanager/latest/userguide/security-encryption.html)
binds a decrypt to its secret. For queue producers, AWS requires decrypt and data
key generation when the reuse period expires; see
[SQS key management](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-key-management.html).
Before activation, verify the queue encryption-context condition against the
reviewed key and actual integration. Do not relax a failed condition into a wildcard.
Customer-managed key policies must separately permit this role or delegate to
IAM; this module deliberately does not manage those policies.

## Handoff and activation blockers

1. Review the exact three secret ARNs, current encryption modes/key ARNs and key
   policies using metadata only. Select KMS inputs accordingly. The role cannot
   authorize an external key policy on its own.
2. Review a foundation plan that adds only the staging role/policy (plus output)
   with these inputs. Apply remains a separately authorized platform action; no
   environment workflow invokes a foundation apply for this feature.
3. After that action, hand off `staging_app_irsa_role_arn` as the reviewed
   `AppIrsaRoleArn` to the staging platform/workload renderer. The existing v1
   foundation export allowlist is unchanged; this output requires an explicit
   reviewed APP/platform handoff. Re-render and hash the workload bundle.
4. Validate IRSA/CSI and a real queue publish in the approved staging window,
   including KMS conditions and resource policies. Offline tests do not establish
   live trust, networking, key-policy access, or runtime readiness. Public runtime
   configuration, migration identity, New Relic account metadata and release
   evidence remain separate reviewed APP inputs.

## Offline checks

```powershell
terraform -chdir=infra/modules/staging-app-irsa init -backend=false -input=false -lockfile=readonly
terraform -chdir=infra/modules/staging-app-irsa validate
terraform -chdir=infra/modules/staging-app-irsa test
terraform -chdir=infra/foundation init -backend=false -input=false
terraform -chdir=infra/foundation validate
terraform -chdir=infra/foundation test
```

AWS is mocked in all test plans; provider installation is the only network
requirement. Tests compare exact trust/policy documents, optional KMS conditions,
invalid references, default disabled wiring and explicit staging-only wiring.
Foundation initialization may prune its historical unused Helm lock entry in the
local checkout; this change preserves the committed foundation lock. Provider
versions remain pinned. The new standalone module initializes with a read-only lock.
