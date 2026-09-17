# Serverless runtime permissions

`infra/functions/{staging,production}` and `infra/modules/functions` are retained as retired historical migration references. They fail closed before planning resources, so this repository cannot become a second Lambda, authorizer, queue or DynamoDB owner. The authoritative runtime roots are `oficina-functions/infra/environments/{staging,production}`, which receive an immutable S3 object version and both SHA-256 encodings. There is no Function URL, Lambda alias, provisioned concurrency, or reserved concurrency.

The API Gateway authorizer ID is a distinct API resource identifier, not a Lambda ARN. K8S owns the base HTTP API, VPC-link integrations, APP routes and stage. FUN owns the Lambda REQUEST authorizer, CPF integrations/routes and exact Lambda invoke permissions. FUN exports the authorizer ID after its API handoff; a later K8S apply consumes that ID to bind protected APP routes.

| Function | Handler | Runtime boundary | IAM boundary |
| --- | --- | --- | --- |
| challenge | `CriarDesafioHandler::handleRequest` | 1024 MiB, 20 seconds | challenge table, auth database/CA ARNs, SES sender |
| verification | `VerificarDesafioHandler::handleRequest` | 1024 MiB, 20 seconds | challenge table, auth database/CA ARNs, customer signing-key ARN |
| authorizer | `AuthorizerHandler::handleRequest` | 1024 MiB, 20 seconds | authorizer-trust ARN only |
| notification | `NotificacaoHandler::handleRequest` | 1024 MiB, 20 seconds | source FIFO receive/delete, delivery ledger, notification database/CA ARNs, SES sender |

All four functions run in the approved private Lambda subnets with the reviewed function security group. Each has a one-day CloudWatch log group, active X-Ray tracing, and JSON logging configuration. Log fields and metric dimensions must use bounded categories only: function name, environment, result class, route key, and event status. They must never include CPF, email, token, OTP, source IP, UUID, or raw request/event body.

## Queue and delivery controls

The source queue and DLQ are encrypted FIFO queues. The source queue uses four-day retention, 120-second visibility, and redrives after five receives to the fourteen-day DLQ. The mapping passes one record at a time and permits at most two notification invocations. It has no Lambda asynchronous DLQ because SQS redrive is the sole retry path.

The challenge and delivery ledgers are separate encrypted DynamoDB tables, each with a `ttl` attribute. DynamoDB TTL performs eventual cleanup only; the FUN use cases enforce expiry, lease, and sequence semantics. The APP runtime receives the emitted publisher policy and can only `sqs:SendMessage` to its own environment's source FIFO ARN.

## Gateway ownership boundary

The K8S platform state is the single owner for the base API, VPC-link integrations, APP target group/routes and stage. Its first apply omits protected APP routes when `authorizer_id` is null. FUN receives the K8S API ID/execution ARN and owns only the REQUEST authorizer, the two public CPF routes and their exact invoke permissions. A reviewed FUN output receipt then supplies `authorizer_id` for the second K8S apply. No state may create a duplicate API, route or Lambda permission.

I4 sets the HTTP API authorizer to payload format 2.0, simple responses, result TTL zero, and no `identity_sources`. That permits F4's explicit `{"errorMessage":"Unauthorized"}` response for absent or invalid bearer credentials while an authenticated, forbidden route returns `{"isAuthorized":false}`. It begins with rate one request/second and burst two. R4 must benchmark real gateway behavior and adjust only within account and runtime limits.

## Secure runtime initialization

Terraform receives only five Secrets Manager **ARNs**: auth database, notification database, customer signing key, combined authorizer trust, and RDS CA certificate. It never receives `secret_string`, `secret_binary`, private key bytes, database password, public-key bytes, CA text, or HMAC value. The approved inventory is exactly 16 secrets; the roots reject any other count rather than creating a bundled replacement secret.

FUN commits `7451d47` and `1c49117` declare the resolver shape. Each database ARN resolves a JSON object with `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, and `DB_PASSWORD`. The signing ARN resolves only `CUSTOMER_PRIVATE_KEY_B64`; the authorizer-trust ARN resolves only `CUSTOMER_PUBLIC_KEY_B64` and `STAFF_HMAC_SECRET`; the CA ARN holds PEM text. The resolver materializes that PEM at the writable `DB_CA_PATH=/tmp/oficina/rds-ca.pem` for JDBC `verify-full`. Challenge does not receive the signing ARN, and the authorizer receives neither database, CA, DynamoDB, SES, queue, nor signing configuration.

The private deployer must run `scripts/check-lambda-artifact.ps1` before calling Terraform with the paired hexadecimal and base64 SHA-256 values. The command rejects a mismatched pair and, when the reviewed JAR is available locally, verifies that it hashes to the same hexadecimal value. This avoids trusting two independently supplied representations of one artifact digest.

Before the private deployment job publishes an alias or binds the platform routes, it must confirm the function IAM roles can resolve their declared ARN configuration. FUN resolves values at cold start; the deployer does not expand secret values into Lambda configuration. Values must not be written to `*.tfvars`, Terraform state, GitHub output, CodeBuild logs, or output artifacts. The deployer verifies all of the following before rollout:

1. The authorizer has only customer public verification material and staff HMAC; its role and environment have no signing key, database, DynamoDB, SES, or notification fields.
2. The verification runtime alone receives the customer private signing key; key rotation publishes the next public key first and keeps old public keys for 900 seconds plus configured clock skew and propagation time.
3. Authentication and notification database JSON secrets use the distinct APP-created read-only views and their RDS CA materializes only at the declared writable `/tmp/oficina/rds-ca.pem` path. IAM access to a lookup secret does not grant a database mutation privilege.
4. `ses_sender_email` is already verified in the SES sandbox. R4 verifies recipient identity, throttling, bounce handling, and production-access prerequisites without sending an unreviewed email.
5. The output artifact contains only allowlisted ARNs, URLs, functions, queue references, and artifact digest. It never contains a secret value.

## Capacity and acceptance gate

Every function consumes `1024 MiB × 20 seconds = 20 GB-seconds` at the configured limit. The required `planned_monthly_invocations` input calculates the maximum monthly envelope from the measured forecast and rejects a total above **200,000 GB-seconds**. F4/F5 handler benchmarks, real API Gateway timeout behavior, cold starts, shared account quota, SQS redrive, DynamoDB conditions, SES throttling, and X-Ray/EMF visibility remain R4 acceptance evidence; mocked Terraform cannot establish those cloud runtime facts.

Run local verification without AWS credentials or apply:

```powershell
terraform -chdir=infra/modules/functions init -backend=false -input=false
terraform -chdir=infra/modules/functions validate
terraform -chdir=infra/modules/functions test
terraform fmt -check -recursive
pwsh ./tests/functions-contract.ps1
pwsh ./tests/lambda-artifact-tests.ps1
pwsh ./tests/functions-fun-contract.ps1 -JavaHome 'C:/Program Files/Eclipse Adoptium/jdk-17.0.20.101-hotspot'
```
