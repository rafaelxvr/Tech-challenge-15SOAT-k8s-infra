# Database executor IAM boundary

The deployment-executor module supplies separate staging and production profiles for `oficina-db-infra`. The reviewed contract remains `releases/database/{environment}`, `database/{environment}.tfstate` (plus `.tflock`) and `/tmp/oficina/database_{environment}.tfvars.json`. No live changes are performed by the tests described here.

## Allowed operations

| Boundary | Permission and restriction |
|---|---|
| RDS lifecycle | Create, describe, modify, delete and tag only the account/region's exact `oficina-phase3-{environment}-postgres` DB instance, subnet group and parameter group. Creation requires project `oficina-phase3`, environment and owner `oficina-db-infra` request tags. Managed-master-password configuration remains enabled when that condition is supplied. Creation rejects a public DB. Parameter modification/reset and instance reboot support parameter application. |
| RDS dependencies | Reference only the default PostgreSQL 16 option group; create/tag only the named `oficina-phase3-{environment}-postgres-final` snapshot and its source DB. There is no snapshot deletion, restore, copy or unrelated option-group mutation grant. |
| DB network | Create security groups only in the reviewed VPC with the three ownership tags. Manage groups only with that VPC and those existing tags. Regional/account generated SG/rule IDs require ARN suffix wildcards; rule authorization additionally checks ownership/request tags because EC2 does not expose `ec2:Vpc` for rule resources. Ingress authorization checks the parent group's VPC. Egress revocation removes EC2's default outbound rule; egress authorization is absent. |
| Network tagging | Creation tags are authorized only in the CreateSecurityGroup/AuthorizeSecurityGroupIngress action context. Later tag changes require existing ownership and cannot change/remove `project`, `environment` or `owner`. |
| Master-secret integration | Only Secrets Manager CreateSecret/TagResource for regional/account `rds!db-*` secrets through RDS forward access, plus KMS DescribeKey for keys carrying `alias/aws/secretsmanager` or `alias/aws/rds`. No secret value reads, runtime-secret creation/writes/deletion, KMS decryption or grants. |
| Outputs | PutObject only in `releases/database/{environment}/outputs/*.json`; no output deletion or other environment writes. Existing source/manifest/config version reads retain their reviewed prefix. |
| State and coordination | Existing exact state Get/Put and exact `.tflock` Get/Put/Delete remain unchanged. The only shared key is `deployment-locks/shared-foundation.json`: Get/Delete plus Put requiring `If-None-Match: *`. The existing lock script validates ownership before release; IAM does not independently validate that ownership metadata. No arbitrary state deletion. |

## Necessary broad resource scopes

The DB profile's sole `Resource: "*"` statement contains EC2 DescribeVpcs, DescribeSubnets, DescribeSecurityGroups and DescribeSecurityGroupRules, plus RDS DescribeDBEngineVersions and DescribeOrderableDBInstanceOptions. These APIs have no resource-level authorization; the statement restricts `aws:RequestedRegion`. Resource-capable RDS Describe/List calls retain exact named ARNs.

The common CodeBuild VPC lifecycle statement and ECR GetAuthorizationToken remain unchanged. Their existing AWS-required `Resource: "*"` scopes support execution rather than granting DB ownership. The separate ENI permission remains CodeBuild-service and private-subnet restricted.

Every normal deployment executor also receives `logs:CreateLogGroup` on its exact declared `/aws/codebuild/{project-name}` group ARN in the configured account/region, with no wildcard or stream suffix. This lets CodeBuild initialize logging before source download, including the database staging executor. The existing CreateLogStream/PutLogEvents grant remains limited to streams inside that same group. No log-group deletion, retention change, or additional group creation is added. The dedicated foundation-addons executor policy is unchanged. The mocked eight-executor test asserts these exact group/stream boundaries for every repository/environment pair; it failed before this permission was added.

## Integration prerequisites and limits

RDS generates the opaque master-secret name before its DB association tag necessarily exists. The secret permission therefore requires `aws:CalledVia = rds.amazonaws.com`; exact named RDS permissions constrain the initiating operation. If request/resource `aws:rds:primaryDBInstanceArn` tags are present, they must match the executor's exact DB ARN. `StringEqualsIfExists` deliberately does not assume RDS copies application environment tags during initial secret creation. Direct secret API calls are not authorized by this statement.

**The RDS forward-access context must still be confirmed during the separately approved live rehearsal.** Mock-provider tests verify generated IAM, not AWS's runtime request context. A missing context fails closed; investigate the actual RDS service call rather than removing the condition or adding secret-value permissions. The RDS service-linked role must already exist (one-time foundation prerequisite); this executor receives no IAM role bootstrap permissions. RDS uses that service role for subsequent managed-secret maintenance. Customer-managed KMS keys are outside this default-key profile.

The APP repository owns schema and runtime-role bootstrap. The old DB profile's `oficina/{environment}/*` secret writes are removed because they do not belong to Terraform's managed-master integration. Existing application, function and Kubernetes profiles are preserved.

## Offline verification

`terraform -chdir=infra/modules/deployment-executor test -no-color` runs `database_permissions_reject_broad_and_cross_environment_scope` for both environments. It asserts every DB statement's exact resources, tag/service/VPC/key conditions, state and lock boundaries, forbidden secret/admin operations, opposite-environment exclusion, and the 10,240-character role inline-policy limit. The existing eight-executor and duplicate-environment tests remain active.

Also run module validation, `terraform -chdir=infra/foundation test -no-color`, `pwsh -NoProfile -File infra/modules/deployment-executor/tests/vpc-codebuild-permissions-contract.ps1`, and `pwsh -NoProfile -File tests/executor-bootstrap-harness.ps1`. All are local/static or use mocked Terraform providers and CLI fixtures; none provisions AWS.

Red/green evidence: the updated provider-capability assertion failed against the old DB profile (one test failed, one passed). After the DB profile change, all three module tests pass, including the new scope assertions. Live IAM authorization and database connectivity are not asserted by this evidence.

## AWS references

- [RDS actions and resource/condition support](https://docs.aws.amazon.com/service-authorization/latest/reference/list_rds.html), [EC2 actions and resources](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html), [Secrets Manager authorization](https://docs.aws.amazon.com/service-authorization/latest/reference/list_secretsmanager.html).
- [RDS-managed password caller prerequisites](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html) and [RDS service-role maintenance policy](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonRDSServiceRolePolicy.html).
- [KMS alias authorization](https://docs.aws.amazon.com/kms/latest/developerguide/alias-authorization.html) and [conditional S3 writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes-enforce.html).
