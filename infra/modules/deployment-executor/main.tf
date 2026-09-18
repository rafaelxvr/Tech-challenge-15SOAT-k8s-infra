locals {
  deployer_repository_name = "${var.name}-deployer"
  project_names = {
    for key, deployment in var.deployments : key => "${var.name}-${replace(deployment.repository, "/", "-")}-${deployment.environment}-deploy"
  }
  eks_describe_actions = ["eks:DescribeCluster"]
  # Base actions from AWS's documented CodeBuild VPC lifecycle policy.
  # CreateNetworkInterfacePermission is granted separately with ENI/subnet/service scope.
  codebuild_vpc_project_actions = [
    "ec2:CreateNetworkInterface",
    "ec2:DescribeDhcpOptions",
    "ec2:DescribeNetworkInterfaces",
    "ec2:DeleteNetworkInterface",
    "ec2:DescribeSubnets",
    "ec2:DescribeSecurityGroups",
    "ec2:DescribeVpcs"
  ]
  eks_node_group_update_actions = [
    "eks:DescribeNodegroup",
    "eks:DescribeUpdate",
    "eks:UpdateNodegroupConfig",
    "eks:UpdateNodegroupVersion"
  ]
  function_gateway_binding_statements = {
    for environment, binding in var.function_gateway_bindings : environment => [
      {
        Sid    = "DiscoverOnlyReviewedEnvironmentGatewayCollections"
        Effect = "Allow"
        Action = ["apigateway:GET"]
        Resource = [
          "arn:aws:apigateway:${var.aws_region}::/apis/${binding.api_id}",
          "arn:aws:apigateway:${var.aws_region}::/apis/${binding.api_id}/authorizers",
          "arn:aws:apigateway:${var.aws_region}::/apis/${binding.api_id}/integrations",
          "arn:aws:apigateway:${var.aws_region}::/apis/${binding.api_id}/routes"
        ]
      },
      {
        Sid    = "CreateOnlyReviewedEnvironmentGatewayBindings"
        Effect = "Allow"
        Action = ["apigateway:POST"]
        Resource = [
          "arn:aws:apigateway:${var.aws_region}::/apis/${binding.api_id}/authorizers",
          "arn:aws:apigateway:${var.aws_region}::/apis/${binding.api_id}/integrations",
          "arn:aws:apigateway:${var.aws_region}::/apis/${binding.api_id}/routes"
        ]
      },
      {
        Sid    = "ManageOnlyReviewedEnvironmentGatewayResources"
        Effect = "Allow"
        Action = ["apigateway:GET", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE"]
        Resource = [
          "arn:aws:apigateway:${var.aws_region}::/apis/${binding.api_id}/authorizers/${binding.authorizer_id}",
          "arn:aws:apigateway:${var.aws_region}::/apis/${binding.api_id}/integrations/${binding.challenge_integration_id}",
          "arn:aws:apigateway:${var.aws_region}::/apis/${binding.api_id}/integrations/${binding.verification_integration_id}",
          "arn:aws:apigateway:${var.aws_region}::/apis/${binding.api_id}/routes/${binding.challenge_route_id}",
          "arn:aws:apigateway:${var.aws_region}::/apis/${binding.api_id}/routes/${binding.verification_route_id}"
        ]
      }
    ]
  }
  # Each repo/environment pair receives a provider profile for the Terraform
  # resources it owns. JSON keeps the conditional profile shapes homogeneous
  # while the generated IAM policy remains fully inspectable in tests.
  executor_permission_profile_documents = {
    for key, deployment in var.deployments : key => deployment.repository == var.kubernetes_repository ? jsonencode({
      profile = "kubernetes-${deployment.environment}"
      statements = [
        {
          Sid      = "ControlOnlyReviewedClusterAndNodeGroups"
          Effect   = "Allow"
          Action   = concat(local.eks_describe_actions, local.eks_node_group_update_actions)
          Resource = concat([var.cluster_arn], var.node_group_arns)
        },
        {
          Sid      = "RunOnlyReviewedKubernetesPlatformProviderActions"
          Effect   = "Allow"
          Action   = ["sts:GetCallerIdentity", "apigateway:GET", "apigateway:POST", "apigateway:PATCH", "apigateway:DELETE", "elasticloadbalancing:DescribeListeners", "elasticloadbalancing:DescribeRules", "elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTags", "elasticloadbalancing:DescribeTargetHealth", "elasticloadbalancing:DescribeListenerAttributes", "elasticloadbalancing:DescribeTargetGroupAttributes", "logs:DescribeLogGroups", "logs:ListTagsForResource", "eks:DescribeAccessPolicy", "eks:ListAssociatedAccessPolicies"]
          Resource = "*"
        },
        {
          Sid      = "ManageOnlyItsClusterAccessEntry"
          Effect   = "Allow"
          Action   = ["eks:CreateAccessEntry", "eks:DeleteAccessEntry", "eks:DescribeAccessEntry", "eks:ListAccessEntries", "eks:AssociateAccessPolicy", "eks:DisassociateAccessPolicy"]
          Resource = var.cluster_arn
        },
        {
          Sid      = "DescribeOnlyItsClusterAccessEntries"
          Effect   = "Allow"
          Action   = ["eks:DescribeAccessEntry"]
          Resource = "arn:aws:eks:${var.aws_region}:${var.account_id}:access-entry/${element(split("/", var.cluster_arn), 1)}/*"
        },
        {
          Sid      = "CreateOnlyTaggedEnvironmentTargetGroups"
          Effect   = "Allow"
          Action   = "elasticloadbalancing:CreateTargetGroup"
          Resource = "*"
          Condition = { StringEquals = {
            "aws:RequestTag/project"     = "oficina-phase3"
            "aws:RequestTag/environment" = deployment.environment
          } }
        },
        {
          Sid    = "ManageOnlyNamedEnvironmentTargetAndListenerRules"
          Effect = "Allow"
          Action = ["elasticloadbalancing:DeleteTargetGroup", "elasticloadbalancing:ModifyTargetGroup", "elasticloadbalancing:ModifyTargetGroupAttributes", "elasticloadbalancing:CreateRule", "elasticloadbalancing:ModifyRule", "elasticloadbalancing:DeleteRule"]
          Resource = [
            "arn:aws:elasticloadbalancing:${var.aws_region}:${var.account_id}:targetgroup/${var.name}-${deployment.environment}-*/*",
            "arn:aws:elasticloadbalancing:${var.aws_region}:${var.account_id}:listener/app/${var.name}-internal/*/*",
            "arn:aws:elasticloadbalancing:${var.aws_region}:${var.account_id}:listener-rule/app/${var.name}-internal/*/*/*"
          ]
        }
      ]
      }) : deployment.repository == "oficina-db-infra" ? jsonencode({
      profile = "database-${deployment.environment}"
      statements = [
        {
          # Catalog/network discovery includes the provider's unfiltered DescribeDBInstances call.
          Sid       = "DescribeDatabaseCatalogAndNetwork"
          Effect    = "Allow"
          Action    = ["ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules", "rds:DescribeDBEngineVersions", "rds:DescribeOrderableDBInstanceOptions", "rds:DescribeDBInstances"]
          Resource  = "*"
          Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
        },
        {
          Sid      = "CreateNamedDatabaseResources"
          Effect   = "Allow"
          Action   = ["rds:CreateDBInstance", "rds:CreateDBSubnetGroup", "rds:CreateDBParameterGroup"]
          Resource = [for type in ["db", "subgrp", "pg"] : "arn:aws:rds:${var.aws_region}:${var.account_id}:${type}:${var.name}-${deployment.environment}-postgres"]
          Condition = {
            StringEquals = { "aws:RequestTag/project" = "oficina-phase3", "aws:RequestTag/environment" = deployment.environment, "aws:RequestTag/owner" = "oficina-db-infra" }
            BoolIfExists = { "rds:ManageMasterUserPassword" = "true", "rds:PubliclyAccessible" = "false" }
          }
        },
        {
          # Resource-capable Describe/List actions remain bound to exact names.
          Sid       = "ManageNamedDatabaseResources"
          Effect    = "Allow"
          Action    = ["rds:ModifyDBInstance", "rds:DeleteDBInstance", "rds:RebootDBInstance", "rds:DescribeDBSubnetGroups", "rds:ModifyDBSubnetGroup", "rds:DeleteDBSubnetGroup", "rds:DescribeDBParameterGroups", "rds:DescribeDBParameters", "rds:ModifyDBParameterGroup", "rds:ResetDBParameterGroup", "rds:DeleteDBParameterGroup", "rds:ListTagsForResource", "rds:AddTagsToResource", "rds:RemoveTagsFromResource"]
          Resource  = [for type in ["db", "subgrp", "pg"] : "arn:aws:rds:${var.aws_region}:${var.account_id}:${type}:${var.name}-${deployment.environment}-postgres"]
          Condition = { BoolIfExists = { "rds:ManageMasterUserPassword" = "true" } }
        },
        {
          # PostgreSQL uses this AWS default option group; no group mutation grant.
          Sid      = "UseDefaultPostgresOptionGroup"
          Effect   = "Allow"
          Action   = ["rds:CreateDBInstance", "rds:ModifyDBInstance"]
          Resource = "arn:aws:rds:${var.aws_region}:${var.account_id}:og:default:postgres-16"
        },
        {
          Sid      = "CreateOnlyDatabaseFinalSnapshot"
          Effect   = "Allow"
          Action   = ["rds:CreateDBSnapshot", "rds:AddTagsToResource"]
          Resource = ["arn:aws:rds:${var.aws_region}:${var.account_id}:db:${var.name}-${deployment.environment}-postgres", "arn:aws:rds:${var.aws_region}:${var.account_id}:snapshot:${var.name}-${deployment.environment}-postgres-final"]
        },
        {
          # EC2 authorizes SG creation against the VPC and the prospective SG separately.
          Sid      = "CreateDatabaseGroupInReviewedVpc"
          Effect   = "Allow"
          Action   = "ec2:CreateSecurityGroup"
          Resource = "arn:aws:ec2:${var.aws_region}:${var.account_id}:vpc/${var.vpc_id}"
        },
        {
          Sid       = "CreateTaggedDatabaseGroup"
          Effect    = "Allow"
          Action    = "ec2:CreateSecurityGroup"
          Resource  = "arn:aws:ec2:${var.aws_region}:${var.account_id}:security-group/*"
          Condition = { StringEquals = { "aws:RequestTag/project" = "oficina-phase3", "aws:RequestTag/environment" = deployment.environment, "aws:RequestTag/owner" = "oficina-db-infra" } }
        },
        {
          # Revoke egress is needed to remove EC2's default allow-all rule on creation.
          Sid      = "ManageDatabaseGroupsInReviewedVpc"
          Effect   = "Allow"
          Action   = ["ec2:DeleteSecurityGroup", "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress", "ec2:ModifySecurityGroupRules"]
          Resource = "arn:aws:ec2:${var.aws_region}:${var.account_id}:security-group/*"
          Condition = {
            ArnEquals    = { "ec2:Vpc" = "arn:aws:ec2:${var.aws_region}:${var.account_id}:vpc/${var.vpc_id}" }
            StringEquals = { "aws:ResourceTag/project" = "oficina-phase3", "aws:ResourceTag/environment" = deployment.environment, "aws:ResourceTag/owner" = "oficina-db-infra" }
          }
        },
        {
          # Tagged rule creation has a second resource authorization; ec2:Vpc is not supported on rule ARNs.
          Sid       = "CreateTaggedDatabaseIngressRules"
          Effect    = "Allow"
          Action    = "ec2:AuthorizeSecurityGroupIngress"
          Resource  = "arn:aws:ec2:${var.aws_region}:${var.account_id}:security-group-rule/*"
          Condition = { StringEquals = { "aws:RequestTag/project" = "oficina-phase3", "aws:RequestTag/environment" = deployment.environment, "aws:RequestTag/owner" = "oficina-db-infra" } }
        },
        {
          Sid       = "ModifyTaggedDatabaseRules"
          Effect    = "Allow"
          Action    = "ec2:ModifySecurityGroupRules"
          Resource  = "arn:aws:ec2:${var.aws_region}:${var.account_id}:security-group-rule/*"
          Condition = { StringEquals = { "aws:ResourceTag/project" = "oficina-phase3", "aws:ResourceTag/environment" = deployment.environment, "aws:ResourceTag/owner" = "oficina-db-infra" } }
        },
        {
          Sid       = "TagDatabaseNetworkResourcesOnCreate"
          Effect    = "Allow"
          Action    = "ec2:CreateTags"
          Resource  = ["arn:aws:ec2:${var.aws_region}:${var.account_id}:security-group/*", "arn:aws:ec2:${var.aws_region}:${var.account_id}:security-group-rule/*"]
          Condition = { StringEquals = { "ec2:CreateAction" = ["CreateSecurityGroup", "AuthorizeSecurityGroupIngress"], "aws:RequestTag/project" = "oficina-phase3", "aws:RequestTag/environment" = deployment.environment, "aws:RequestTag/owner" = "oficina-db-infra" } }
        },
        {
          Sid      = "RetagOnlyOwnedDatabaseNetworkResources"
          Effect   = "Allow"
          Action   = ["ec2:CreateTags", "ec2:DeleteTags"]
          Resource = ["arn:aws:ec2:${var.aws_region}:${var.account_id}:security-group/*", "arn:aws:ec2:${var.aws_region}:${var.account_id}:security-group-rule/*"]
          Condition = {
            StringEquals                   = { "aws:ResourceTag/project" = "oficina-phase3", "aws:ResourceTag/environment" = deployment.environment, "aws:ResourceTag/owner" = "oficina-db-infra" }
            "ForAllValues:StringNotEquals" = { "aws:TagKeys" = ["project", "environment", "owner"] }
          }
        },
        {
          # RDS generates the opaque secret name. Creation has no existing environment tag;
          # the exact DB ARN permissions above and CalledVia constrain that initial operation.
          Sid      = "CreateAndTagOnlyRdsManagedMasterSecret"
          Effect   = "Allow"
          Action   = ["secretsmanager:CreateSecret", "secretsmanager:TagResource"]
          Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:rds!db-*"
          Condition = {
            "ForAnyValue:StringEquals" = { "aws:CalledVia" = ["rds.amazonaws.com"] }
            StringEqualsIfExists = {
              "aws:RequestTag/aws:rds:primaryDBInstanceArn"  = "arn:aws:rds:${var.aws_region}:${var.account_id}:db:${var.name}-${deployment.environment}-postgres"
              "aws:ResourceTag/aws:rds:primaryDBInstanceArn" = "arn:aws:rds:${var.aws_region}:${var.account_id}:db:${var.name}-${deployment.environment}-postgres"
            }
          }
        },
        {
          Sid       = "DescribeOnlyAwsManagedDatabaseKeys"
          Effect    = "Allow"
          Action    = "kms:DescribeKey"
          Resource  = "arn:aws:kms:${var.aws_region}:${var.account_id}:key/*"
          Condition = { "ForAnyValue:StringEquals" = { "kms:ResourceAliases" = ["alias/aws/secretsmanager", "alias/aws/rds"] } }
        },
        {
          Sid      = "PublishOnlyDatabaseEnvironmentOutputs"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "arn:aws:s3:::${var.artifact_bucket_name}/releases/database/${deployment.environment}/outputs/*.json"
        },
        {
          Sid      = "ReadAndReleaseSharedFoundationLock"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:DeleteObject"]
          Resource = "arn:aws:s3:::${var.state_bucket_name}/deployment-locks/shared-foundation.json"
        },
        {
          Sid       = "AcquireSharedFoundationLockConditionally"
          Effect    = "Allow"
          Action    = "s3:PutObject"
          Resource  = "arn:aws:s3:::${var.state_bucket_name}/deployment-locks/shared-foundation.json"
          Condition = { StringEquals = { "s3:if-none-match" = "*" } }
        }
      ]
      }) : deployment.repository == "oficina-functions" ? jsonencode({
      profile = "functions-${deployment.environment}"
      statements = concat([
        {
          Sid       = "ManageOnlyTaggedEnvironmentFunctions"
          Effect    = "Allow"
          Action    = ["lambda:CreateFunction"]
          Resource  = "*"
          Condition = { StringEquals = { "aws:RequestTag/project" = "oficina-phase3", "aws:RequestTag/environment" = deployment.environment } }
        },
        {
          Sid      = "ManageOnlyNamedEnvironmentFunctions"
          Effect   = "Allow"
          Action   = ["lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration", "lambda:DeleteFunction", "lambda:PublishVersion", "lambda:ListVersionsByFunction", "lambda:TagResource", "lambda:UntagResource"]
          Resource = "arn:aws:lambda:${var.aws_region}:${var.account_id}:function:${var.name}-${deployment.environment}-*"
        },
        {
          Sid    = "ReadOnlyEnvironmentFunctionCodeSigningConfigurations"
          Effect = "Allow"
          Action = ["lambda:GetFunctionCodeSigningConfig"]
          Resource = [
            for function_name in ["authorizer", "challenge", "verification", "notification"] :
            "arn:aws:lambda:${var.aws_region}:${var.account_id}:function:${var.name}-${deployment.environment}-${function_name}"
          ]
        },
        {
          Sid      = "ManageOnlyEnvironmentFunctionEventMappings"
          Effect   = "Allow"
          Action   = ["lambda:CreateEventSourceMapping", "lambda:UpdateEventSourceMapping", "lambda:DeleteEventSourceMapping", "lambda:ListEventSourceMappings"]
          Resource = "*"
          # Event-source mapping ARNs are generated by Lambda, so CRUD/list
          # must use Resource="*" with the documented function ARN condition.
          # Keep the condition exact to the notification consumer; a wildcard
          # here would permit mappings for every function in the environment.
          Condition = { ArnEquals = {
            "lambda:FunctionArn" = "arn:aws:lambda:${var.aws_region}:${var.account_id}:function:${var.name}-${deployment.environment}-notification"
          } }
        },
        {
          Sid    = "ReadOnlyEnvironmentEventSourceMappingMetadata"
          Effect = "Allow"
          Action = ["lambda:GetEventSourceMapping", "lambda:ListTags"]
          # Lambda mapping metadata APIs evaluate these read-only calls against
          # the wildcard resource, so keep this statement separate from the
          # function-scoped mapping management actions above.
          Resource = "*"
        },
        {
          Sid      = "ManageOnlyEnvironmentFunctionInvokePermissions"
          Effect   = "Allow"
          Action   = ["lambda:AddPermission", "lambda:RemovePermission", "lambda:GetPolicy"]
          Resource = "arn:aws:lambda:${var.aws_region}:${var.account_id}:function:${var.name}-${deployment.environment}-*"
        },
        {
          # Functions receive secret ARNs as configuration references. A
          # deployer may inspect metadata for those exact name families, but
          # it never receives secret values.
          Sid    = "DescribeOnlyEnvironmentRuntimeSecretReferences"
          Effect = "Allow"
          Action = ["secretsmanager:DescribeSecret"]
          Resource = [
            for secret_name in ["auth-lookup", "notification-lookup", "customer-signing", "authorizer-trust", "rds-ca", "newrelic-ingest"] :
            "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:oficina/${deployment.environment}/${secret_name}-*"
          ]
        },
        {
          Sid       = "CreateOnlyTaggedEnvironmentQueuesAndTables"
          Effect    = "Allow"
          Action    = ["sqs:CreateQueue", "dynamodb:CreateTable"]
          Resource  = "*"
          Condition = { StringEquals = { "aws:RequestTag/project" = "oficina-phase3", "aws:RequestTag/environment" = deployment.environment } }
        },
        {
          Sid      = "ManageOnlyNamedEnvironmentQueue"
          Effect   = "Allow"
          Action   = ["sqs:GetQueueAttributes", "sqs:SetQueueAttributes", "sqs:DeleteQueue", "sqs:ListQueueTags", "sqs:TagQueue", "sqs:UntagQueue"]
          Resource = "arn:aws:sqs:${var.aws_region}:${var.account_id}:${var.name}-${deployment.environment}-*"
        },
        {
          Sid      = "ManageOnlyNamedEnvironmentTables"
          Effect   = "Allow"
          Action   = ["dynamodb:DescribeTable", "dynamodb:UpdateTable", "dynamodb:DeleteTable", "dynamodb:DescribeContinuousBackups", "dynamodb:UpdateContinuousBackups", "dynamodb:DescribeTimeToLive", "dynamodb:UpdateTimeToLive", "dynamodb:ListTagsOfResource", "dynamodb:TagResource", "dynamodb:UntagResource"]
          Resource = "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/${var.name}-${deployment.environment}-*"
        },
        {
          Sid      = "CreateOnlyTaggedEnvironmentAlarmTopic"
          Effect   = "Allow"
          Action   = ["sns:CreateTopic"]
          Resource = "arn:aws:sns:${var.aws_region}:${var.account_id}:${var.name}-${deployment.environment}-native-alarms"
          Condition = { StringEquals = {
            "aws:RequestTag/project"     = "oficina-phase3"
            "aws:RequestTag/environment" = deployment.environment
          } }
        },
        {
          Sid      = "TagOnlyEnvironmentAlarmTopicOnCreate"
          Effect   = "Allow"
          Action   = ["sns:TagResource"]
          Resource = "arn:aws:sns:${var.aws_region}:${var.account_id}:${var.name}-${deployment.environment}-native-alarms"
          Condition = { StringEquals = {
            "aws:RequestTag/project"     = "oficina-phase3"
            "aws:RequestTag/environment" = deployment.environment
          } }
        },
        {
          Sid      = "ManageOnlyEnvironmentAlarmTopic"
          Effect   = "Allow"
          Action   = ["sns:GetTopicAttributes", "sns:SetTopicAttributes", "sns:DeleteTopic", "sns:ListTagsForResource", "sns:UntagResource"]
          Resource = "arn:aws:sns:${var.aws_region}:${var.account_id}:${var.name}-${deployment.environment}-native-alarms"
          Condition = { StringEquals = {
            "aws:ResourceTag/project"     = "oficina-phase3"
            "aws:ResourceTag/environment" = deployment.environment
          } }
        },
        {
          Sid    = "ManageOnlyEnvironmentAlarmSubscriptions"
          Effect = "Allow"
          Action = ["sns:Subscribe", "sns:Unsubscribe", "sns:GetSubscriptionAttributes", "sns:SetSubscriptionAttributes"]
          Resource = [
            "arn:aws:sns:${var.aws_region}:${var.account_id}:${var.name}-${deployment.environment}-native-alarms",
            "arn:aws:sns:${var.aws_region}:${var.account_id}:${var.name}-${deployment.environment}-native-alarms:*"
          ]
        },
        {
          Sid      = "ManageOnlyEnvironmentNativeAlarms"
          Effect   = "Allow"
          Action   = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:EnableAlarmActions", "cloudwatch:DisableAlarmActions", "cloudwatch:ListTagsForResource", "cloudwatch:TagResource", "cloudwatch:UntagResource"]
          Resource = "arn:aws:cloudwatch:${var.aws_region}:${var.account_id}:alarm:${var.name}-${deployment.environment}-*"
        },
        {
          # CloudWatch does not support resource-level authorization for
          # DescribeAlarms; keep the read action separate from alarm mutation.
          Sid       = "DescribeOnlyEnvironmentNativeAlarms"
          Effect    = "Allow"
          Action    = ["cloudwatch:DescribeAlarms"]
          Resource  = "*"
          Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
        },
        {
          Sid      = "ManageOnlyNamedEnvironmentFunctionRoles"
          Effect   = "Allow"
          Action   = ["iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:TagRole", "iam:UntagRole", "iam:PassRole"]
          Resource = "arn:aws:iam::${var.account_id}:role/${var.name}-${deployment.environment}-*"
        },
        {
          Sid      = "ManageOnlyNamedEnvironmentPublisherPolicy"
          Effect   = "Allow"
          Action   = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:DeletePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:TagPolicy", "iam:UntagPolicy"]
          Resource = "arn:aws:iam::${var.account_id}:policy/${var.name}-${deployment.environment}-notification-publisher"
        },
        {
          Sid       = "CreateOnlyTaggedEnvironmentPublisherPolicy"
          Effect    = "Allow"
          Action    = ["iam:CreatePolicy"]
          Resource  = "*"
          Condition = { StringEquals = { "aws:RequestTag/project" = "oficina-phase3", "aws:RequestTag/environment" = deployment.environment } }
        },
        {
          Sid      = "ManageOnlyEnvironmentFunctionLogs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:TagResource", "logs:UntagResource"]
          Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/lambda/${var.name}-${deployment.environment}-*"
        },
        {
          Sid      = "ReadAndReleaseSharedFoundationLock"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:DeleteObject"]
          Resource = "arn:aws:s3:::${var.state_bucket_name}/deployment-locks/shared-foundation.json"
        },
        {
          Sid       = "AcquireSharedFoundationLockConditionally"
          Effect    = "Allow"
          Action    = "s3:PutObject"
          Resource  = "arn:aws:s3:::${var.state_bucket_name}/deployment-locks/shared-foundation.json"
          Condition = { StringEquals = { "s3:if-none-match" = "*" } }
        }
        ], try(local.function_gateway_binding_statements[deployment.environment], []), var.newrelic_layer_version_arns == null ? [] : [{
          Sid      = "ReadOnlyPinnedNewRelicLayerVersions"
          Effect   = "Allow"
          Action   = ["lambda:GetLayerVersion"]
          Resource = [var.newrelic_layer_version_arns.java_slim, var.newrelic_layer_version_arns.extension]
      }])
      }) : jsonencode({
      profile = "application-${deployment.environment}"
      statements = concat([
        {
          Sid      = "RolloutOnlyReviewedCluster"
          Effect   = "Allow"
          Action   = ["eks:DescribeCluster"]
          Resource = var.cluster_arn
        },
        {
          Sid      = "ReadOnlyEnvironmentContainerImages"
          Effect   = "Allow"
          Action   = ["ecr:DescribeImages", "ecr:BatchGetImage"]
          Resource = "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/${var.name}-${deployment.environment}-*"
        }
        ], deployment.repository == "oficina-app" && deployment.environment == "staging" ? [{
          Sid      = "ReadOnlyStagingAppReleaseImages"
          Effect   = "Allow"
          Action   = ["ecr:DescribeImages", "ecr:BatchGetImage"]
          Resource = "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/${var.name}-app"
          }] : [], flatten([for _ in(deployment.repository == "oficina-app" && deployment.environment == "staging" && contains(keys(var.application_bootstrap_secret_refs), "staging") ? [true] : []) : [
            {
              Sid       = "ReadOnlyReviewedApplicationBootstrapSecrets"
              Effect    = "Allow"
              Action    = ["secretsmanager:GetSecretValue"]
              Resource  = [for key in ["master", "migration", "app", "auth", "notification"] : var.application_bootstrap_secret_refs.staging[key].arn]
              Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
            },
            {
              Sid       = "DescribeOnlyReviewedApplicationBootstrapDatabase"
              Effect    = "Allow"
              Action    = ["rds:DescribeDBInstances"]
              Resource  = var.application_bootstrap_secret_refs.staging.database_arn
              Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
            }
      ]]))
    })
  }
  codebuild_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CodeBuildOnly"
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })
  codebuild_policies = {
    for key, deployment in var.deployments : key => jsonencode({
      Version = "2012-10-17"
      Statement = concat([
        {
          Sid      = "ReadOnlyReviewedSourcePrefix"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:GetObjectVersion"]
          Resource = "arn:aws:s3:::${var.artifact_bucket_name}/${deployment.source_prefix}/*"
        },
        {
          # CreateLogGroup authorizes the group ARN itself, without a stream suffix.
          Sid      = "CreateOnlyThisBuildLogGroup"
          Effect   = "Allow"
          Action   = "logs:CreateLogGroup"
          Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/codebuild/${local.project_names[key]}"
        },
        {
          Sid      = "WriteOnlyThisBuildLogGroup"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/codebuild/${local.project_names[key]}:log-stream:*"
        },
        # CodeBuild creates and removes VPC network interfaces for each private executor.
        # Preserve the base scope from AWS's documented CodeBuild VPC policy.
        {
          Sid      = "CodeBuildVpcNetworkInterfaces"
          Effect   = "Allow"
          Action   = local.codebuild_vpc_project_actions
          Resource = "*"
        },
        {
          Sid      = "CodeBuildVpcNetworkInterfacePermission"
          Effect   = "Allow"
          Action   = "ec2:CreateNetworkInterfacePermission"
          Resource = "arn:aws:ec2:${var.aws_region}:${var.account_id}:network-interface/*"
          Condition = {
            StringEquals = { "ec2:AuthorizedService" = "codebuild.amazonaws.com" }
            ArnEquals    = { "ec2:Subnet" = [for subnet in var.private_subnet_ids : "arn:aws:ec2:${var.aws_region}:${var.account_id}:subnet/${subnet}"] }
          }
        },
        {
          Sid      = "PullOnlyPlatformDeployerImage"
          Effect   = "Allow"
          Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
          Resource = aws_ecr_repository.deployer.arn
        },
        # AWS requires Resource=* for this account-scoped token action. Layer
        # and image retrieval stay restricted to the platform repository above.
        {
          Sid      = "AuthenticateOnlyToPullPlatformImage"
          Effect   = "Allow"
          Action   = "ecr:GetAuthorizationToken"
          Resource = "*"
        },
        {
          Sid       = "ListOnlyItsTerraformStatePrefix"
          Effect    = "Allow"
          Action    = "s3:ListBucket"
          Resource  = "arn:aws:s3:::${var.state_bucket_name}"
          Condition = { StringLike = { "s3:prefix" = [deployment.terraform_state_key, "${deployment.terraform_state_key}.tflock"] } }
        },
        {
          Sid      = "ReadWriteOnlyItsTerraformState"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject"]
          Resource = "arn:aws:s3:::${var.state_bucket_name}/${deployment.terraform_state_key}"
        },
        {
          Sid      = "LockOnlyItsTerraformLockfile"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = "arn:aws:s3:::${var.state_bucket_name}/${deployment.terraform_state_key}.tflock"
        }
      ], jsondecode(local.executor_permission_profile_documents[key]).statements)
    })
  }
  # The executor's buildspec is Terraform-owned. Nothing from the archive is
  # executed until this bootstrap has re-downloaded the exact object version
  # and verified both the source and release-manifest digests.
  inline_deployment_buildspec_template = <<-YAML
    version: 0.2
    phases:
      build:
        commands:
          - |
            set -euo pipefail
            reviewed_environment="__DEPLOYMENT_ENVIRONMENT__"
            reviewed_repository="__REPOSITORY__"
            reviewed_backend_bucket="__TERRAFORM_BACKEND_BUCKET__"
            reviewed_backend_key="__TERRAFORM_BACKEND_KEY__"
            reviewed_backend_lock_key="__TERRAFORM_BACKEND_LOCK_KEY__"
            reviewed_backend_region="__TERRAFORM_BACKEND_REGION__"
            reviewed_deployment_mode="__DEPLOYMENT_MODE__"
            reviewed_tfvars_path="__DEPLOYMENT_TFVARS_PATH__"
            required=(DEPLOY_ENVIRONMENT SOURCE_BUCKET SOURCE_KEY SOURCE_VERSION_ID EXPECTED_SHA256 RELEASE_MANIFEST_KEY RELEASE_MANIFEST_VERSION_ID EXPECTED_MANIFEST_SHA256 SOURCE_COMMIT DEPLOYER_IMAGE_DIGEST)
            for variable in "$${required[@]}"; do
              if [ -z "$${!variable:-}" ]; then
                echo "Required deployment input is missing: $${variable}"
                exit 1
              fi
            done
            if [ "$${reviewed_deployment_mode}" != "plan" ] && [ "$${reviewed_deployment_mode}" != "apply" ]; then
              echo 'Reviewed deployment mode must be plan or apply.'
              exit 1
            fi
            if [ "$${DEPLOY_ENVIRONMENT}" != "$${reviewed_environment}" ]; then
              echo 'Deployment environment override does not match this reviewed executor.'
              exit 1
            fi
            if [ "$${reviewed_backend_lock_key}" != "$${reviewed_backend_key}.tflock" ]; then
              echo 'Terraform backend lock key is not derived from the reviewed state key.'
              exit 1
            fi
            workdir="$(mktemp -d)"
            trap 'rm -rf "$${workdir}"' EXIT
            aws s3api get-object --bucket "$${SOURCE_BUCKET}" --key "$${SOURCE_KEY}" --version-id "$${SOURCE_VERSION_ID}" "$${workdir}/bundle.zip" >/dev/null
            actual_sha="$(sha256sum "$${workdir}/bundle.zip" | awk '{print $1}')"
            if [ "$${actual_sha}" != "$${EXPECTED_SHA256}" ]; then
              echo 'Source digest mismatch.'
              exit 1
            fi
            aws s3api get-object --bucket "$${SOURCE_BUCKET}" --key "$${RELEASE_MANIFEST_KEY}" --version-id "$${RELEASE_MANIFEST_VERSION_ID}" "$${workdir}/release-manifest.json" >/dev/null
            actual_manifest_sha="$(sha256sum "$${workdir}/release-manifest.json" | awk '{print $1}')"
            if [ "$${actual_manifest_sha}" != "$${EXPECTED_MANIFEST_SHA256}" ]; then
              echo 'Release manifest digest mismatch.'
              exit 1
            fi
            for variable in TFVARS_OBJECT_KEY TFVARS_VERSION_ID EXPECTED_TFVARS_SHA256; do
              if [ -z "$${!variable:-}" ]; then echo "Required Terraform variables input is missing: $${variable}"; exit 1; fi
            done
            mkdir -p "$(dirname "$${reviewed_tfvars_path}")"
            aws s3api get-object --bucket "$${SOURCE_BUCKET}" --key "$${TFVARS_OBJECT_KEY}" --version-id "$${TFVARS_VERSION_ID}" "$${reviewed_tfvars_path}" >/dev/null
            actual_tfvars_sha="$(sha256sum "$${reviewed_tfvars_path}" | awk '{print $1}')"
            if [ "$${actual_tfvars_sha}" != "$${EXPECTED_TFVARS_SHA256}" ]; then
              echo 'Terraform variables digest mismatch.'
              exit 1
            fi
            unzip -q "$${workdir}/bundle.zip" -d "$${workdir}/release"
            apply_switch=()
            if [ "$${reviewed_deployment_mode}" = "apply" ]; then apply_switch=(-ApplyReviewedPlan); fi
            functions_tfvars_digest_switch=()
            functions_shared_lock_switch=()
            if [ "$${reviewed_repository}" = "oficina-functions" ]; then
              functions_tfvars_digest_switch=(-ExpectedTerraformVariablesSha256 "$${EXPECTED_TFVARS_SHA256}")
              functions_shared_lock_switch=(-StateBucket "$${reviewed_backend_bucket}" -SharedFoundationMutation)
            fi
            pwsh -NoLogo -NoProfile -File "$${workdir}/release/scripts/deploy.ps1" -Environment "$${reviewed_environment}" -ReleaseManifest "$${workdir}/release-manifest.json" -ExpectedSourceSha256 "$${EXPECTED_SHA256}" -ExpectedManifestSha256 "$${EXPECTED_MANIFEST_SHA256}" "$${functions_tfvars_digest_switch[@]}" "$${functions_shared_lock_switch[@]}" -SourceCommit "$${SOURCE_COMMIT}" -ExpectedDeployerImageDigest "$${DEPLOYER_IMAGE_DIGEST}" -TerraformVariablesFile "$${reviewed_tfvars_path}" -TerraformBackendBucket "$${reviewed_backend_bucket}" -TerraformBackendKey "$${reviewed_backend_key}" -TerraformBackendLockKey "$${reviewed_backend_lock_key}" -TerraformBackendRegion "$${reviewed_backend_region}" "$${apply_switch[@]}"
  YAML
  # This is the exact buildspec passed to each aws_codebuild_project.deploy
  # source block below. Tests render this local through Terraform, then run
  # the resulting shell bootstrap with mocked process dependencies.
  rendered_deployment_buildspecs = {
    for key, deployment in var.deployments : key => replace(replace(replace(replace(replace(replace(replace(replace(
      local.inline_deployment_buildspec_template,
      "__DEPLOYMENT_ENVIRONMENT__", deployment.environment),
      "__REPOSITORY__", deployment.repository),
      "__TERRAFORM_BACKEND_BUCKET__", var.state_bucket_name),
      "__TERRAFORM_BACKEND_KEY__", deployment.terraform_state_key),
      "__TERRAFORM_BACKEND_LOCK_KEY__", "${deployment.terraform_state_key}.tflock"),
      "__TERRAFORM_BACKEND_REGION__", var.aws_region),
      "__DEPLOYMENT_MODE__", deployment.deployment_mode),
    "__DEPLOYMENT_TFVARS_PATH__", deployment.terraform_variables_path)
  }
}

resource "aws_ecr_repository" "deployer" {
  name                 = local.deployer_repository_name
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}

resource "aws_ecr_lifecycle_policy" "deployer" {
  repository = aws_ecr_repository.deployer.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Retain one reviewed deployer image within the approved retained-image allowance."
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 1 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_iam_role" "codebuild" {
  for_each           = var.deployments
  name               = "${local.project_names[each.key]}-role"
  assume_role_policy = local.codebuild_assume_role_policy
}

resource "aws_iam_role_policy" "codebuild" {
  for_each = var.deployments
  name     = "bounded-deployment-executor"
  role     = aws_iam_role.codebuild[each.key].id
  policy   = local.codebuild_policies[each.key]
}

resource "aws_codebuild_project" "deploy" {
  for_each               = var.deployments
  name                   = local.project_names[each.key]
  description            = "Short-lived private deployment executor for ${each.value.repository}/${each.value.environment}."
  service_role           = aws_iam_role.codebuild[each.key].arn
  build_timeout          = 30
  queued_timeout         = 30
  concurrent_build_limit = 1

  artifacts { type = "NO_ARTIFACTS" }
  source {
    type     = "S3"
    location = "${var.artifact_bucket_name}/${each.value.source_prefix}/bundle.zip"
    # State selection and deploy controls are Terraform-rendered literals.
    # StartBuild environmentVariablesOverride cannot alter these values.
    buildspec = local.rendered_deployment_buildspecs[each.key]
  }
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "${aws_ecr_repository.deployer.repository_url}@${var.deployer_image_digest}"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "SERVICE_ROLE"
    privileged_mode             = false
  }
  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = var.private_subnet_ids
    security_group_ids = var.security_group_ids
  }
  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${local.project_names[each.key]}"
      stream_name = "deploy"
    }
  }
}
