mock_provider "aws" {}

variables {
  name                  = "oficina-phase3"
  aws_region            = "us-east-1"
  account_id            = "123456789012"
  vpc_id                = "vpc-12345678"
  cluster_arn           = "arn:aws:eks:us-east-1:123456789012:cluster/oficina-phase3"
  node_group_arns       = ["arn:aws:eks:us-east-1:123456789012:nodegroup/oficina-phase3/workers-a/example", "arn:aws:eks:us-east-1:123456789012:nodegroup/oficina-phase3/workers-b/example"]
  kubernetes_repository = "oficina-k8s-infra"
  artifact_bucket_name  = "oficina-phase3-artifacts-example"
  state_bucket_name     = "oficina-phase3-state-example"
  private_subnet_ids    = ["subnet-a", "subnet-b"]
  security_group_ids    = ["sg-codebuild"]
  deployer_image_digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  function_gateway_bindings = {
    staging = {
      api_id                      = "stage123"
      authorizer_id               = "authstage"
      challenge_integration_id    = "intstage1"
      verification_integration_id = "intstage2"
      challenge_route_id          = "routestage1"
      verification_route_id       = "routestage2"
    }
    production = {
      api_id                      = "prod456"
      authorizer_id               = "authprod"
      challenge_integration_id    = "intprod1"
      verification_integration_id = "intprod2"
      challenge_route_id          = "routeprod1"
      verification_route_id       = "routeprod2"
    }
  }
  newrelic_layer_version_arns = {
    java_slim = "arn:aws:lambda:us-east-1:451483290750:layer:NewRelicJava17:29"
    extension = "arn:aws:lambda:us-east-1:451483290750:layer:NewRelicLambdaExtension:77"
  }
  application_bootstrap_secret_refs = {
    staging = {
      database_arn = "arn:aws:rds:us-east-1:123456789012:db:oficina-phase3-staging-postgres"
      master       = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-0123456789abcdef", version_id = "12345678901234567890123456789012", database_arn = "arn:aws:rds:us-east-1:123456789012:db:oficina-phase3-staging-postgres" }
      migration    = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/migration-AbCdEf", version_id = "23456789012345678901234567890123" }
      app          = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/app-AbCdEf", version_id = "34567890123456789012345678901234" }
      auth         = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/auth-AbCdEf", version_id = "45678901234567890123456789012345" }
      notification = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/notification-AbCdEf", version_id = "56789012345678901234567890123456" }
    }
  }
  deployments = {
    k8s_staging          = { repository = "oficina-k8s-infra", environment = "staging", source_prefix = "releases/k8s/staging", terraform_state_key = "environments/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/k8s_staging.tfvars.json" }
    k8s_production       = { repository = "oficina-k8s-infra", environment = "production", source_prefix = "releases/k8s/production", terraform_state_key = "environments/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/k8s_production.tfvars.json" }
    db_staging           = { repository = "oficina-db-infra", environment = "staging", source_prefix = "releases/database/staging", terraform_state_key = "database/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/database_staging.tfvars.json" }
    db_production        = { repository = "oficina-db-infra", environment = "production", source_prefix = "releases/database/production", terraform_state_key = "database/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/database_production.tfvars.json" }
    functions_staging    = { repository = "oficina-functions", environment = "staging", source_prefix = "releases/functions/staging", terraform_state_key = "functions/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/functions_staging.tfvars.json" }
    functions_production = { repository = "oficina-functions", environment = "production", source_prefix = "releases/functions/production", terraform_state_key = "functions/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/functions_production.tfvars.json" }
    app_staging          = { repository = "oficina-app", environment = "staging", source_prefix = "releases/app/staging", terraform_state_key = "app/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/app_staging.tfvars.json" }
    app_production       = { repository = "oficina-app", environment = "production", source_prefix = "releases/app/production", terraform_state_key = "app/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/app_production.tfvars.json" }
  }
}

run "eight_bounded_private_deployers" {
  command = plan
  assert {
    condition = alltrue([for key, project in aws_codebuild_project.deploy :
      one([for statement in jsondecode(local.codebuild_policies[key]).Statement : statement if statement.Sid == "CreateOnlyThisBuildLogGroup"]) == {
        Sid      = "CreateOnlyThisBuildLogGroup"
        Effect   = "Allow"
        Action   = "logs:CreateLogGroup"
        Resource = "arn:aws:logs:us-east-1:123456789012:log-group:${project.logs_config[0].cloudwatch_logs[0].group_name}"
      } &&
      one([for statement in jsondecode(local.codebuild_policies[key]).Statement : statement if statement.Sid == "WriteOnlyThisBuildLogGroup"]) == {
        Sid      = "WriteOnlyThisBuildLogGroup"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:us-east-1:123456789012:log-group:${project.logs_config[0].cloudwatch_logs[0].group_name}:log-stream:*"
      } &&
      project.logs_config[0].cloudwatch_logs[0].group_name == "/aws/codebuild/${project.name}" &&
      !strcontains(project.logs_config[0].cloudwatch_logs[0].group_name, "*")
    ])
    error_message = "Every deployment executor may create only its declared exact account/region log group, and may create streams/write events only inside that same group."
  }
  assert {
    condition = one([for statement in jsondecode(local.executor_permission_profile_documents["app_staging"]).statements : statement if statement.Sid == "ReadOnlyReviewedApplicationBootstrapSecrets"]) == {
      Sid    = "ReadOnlyReviewedApplicationBootstrapSecrets"
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-0123456789abcdef",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/migration-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/app-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/auth-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/notification-AbCdEf"
      ]
      Condition = { StringEquals = { "aws:RequestedRegion" = "us-east-1" } }
      } && one([for statement in jsondecode(local.executor_permission_profile_documents["app_staging"]).statements : statement if statement.Sid == "DescribeOnlyReviewedApplicationBootstrapDatabase"]) == {
      Sid       = "DescribeOnlyReviewedApplicationBootstrapDatabase"
      Effect    = "Allow"
      Action    = ["rds:DescribeDBInstances"]
      Resource  = "arn:aws:rds:us-east-1:123456789012:db:oficina-phase3-staging-postgres"
      Condition = { StringEquals = { "aws:RequestedRegion" = "us-east-1" } }
    } && !strcontains(local.executor_permission_profile_documents["app_production"], "ReadOnlyReviewedApplicationBootstrapSecrets")
    error_message = "Only the reviewed staging application executor may read the exact bootstrap secret ARNs or describe the exact staging database ARN."
  }
  assert {
    condition = alltrue([for environment in ["staging", "production"] :
      aws_codebuild_project.deploy["db_${environment}"].source[0].location == "${var.artifact_bucket_name}/releases/database/${environment}/bundle.zip" &&
      strcontains(local.rendered_deployment_buildspecs["db_${environment}"], "reviewed_backend_key=\"database/${environment}.tfstate\"") &&
      strcontains(local.rendered_deployment_buildspecs["db_${environment}"], "reviewed_backend_lock_key=\"database/${environment}.tfstate.tflock\"") &&
      strcontains(local.rendered_deployment_buildspecs["db_${environment}"], "reviewed_tfvars_path=\"/tmp/oficina/database_${environment}.tfvars.json\"")
    ])
    error_message = "Both DB executors must match the approved database source, state/lock and trusted tfvars contract."
  }
  override_resource {
    target          = aws_ecr_repository.deployer
    override_during = plan
    values = {
      arn = "arn:aws:ecr:us-east-1:123456789012:repository/oficina-phase3-deployer"
    }
  }
  assert {
    condition = alltrue([
      for policy in values(local.codebuild_policies) : one([
        for statement in jsondecode(policy).Statement : statement
        if statement.Sid == "CodeBuildVpcNetworkInterfacePermission"
        ]) == {
        Sid      = "CodeBuildVpcNetworkInterfacePermission"
        Effect   = "Allow"
        Action   = "ec2:CreateNetworkInterfacePermission"
        Resource = "arn:aws:ec2:us-east-1:123456789012:network-interface/*"
        Condition = {
          StringEquals = { "ec2:AuthorizedService" = "codebuild.amazonaws.com" }
          ArnEquals = {
            "ec2:Subnet" = ["arn:aws:ec2:us-east-1:123456789012:subnet/subnet-a", "arn:aws:ec2:us-east-1:123456789012:subnet/subnet-b"]
          }
        }
      }
    ])
    error_message = "Every executor must restrict ENI permission to CodeBuild, its configured account/region and both private subnets."
  }
  assert {
    condition     = length(aws_codebuild_project.deploy) == 8 && alltrue([for project in aws_codebuild_project.deploy : project.concurrent_build_limit == 1 && project.environment[0].compute_type == "BUILD_GENERAL1_SMALL" && project.environment[0].image_pull_credentials_type == "SERVICE_ROLE" && !project.environment[0].privileged_mode && project.source[0].type == "S3"])
    error_message = "The four repositories require exactly eight bounded, S3-sourced non-privileged deployers."
  }
  assert {
    condition = alltrue([
      jsondecode(local.executor_permission_profile_documents["k8s_staging"]).profile == "kubernetes-staging",
      jsondecode(local.executor_permission_profile_documents["k8s_production"]).profile == "kubernetes-production",
      jsondecode(local.executor_permission_profile_documents["db_staging"]).profile == "database-staging",
      jsondecode(local.executor_permission_profile_documents["db_production"]).profile == "database-production",
      jsondecode(local.executor_permission_profile_documents["functions_staging"]).profile == "functions-staging",
      jsondecode(local.executor_permission_profile_documents["functions_production"]).profile == "functions-production",
      jsondecode(local.executor_permission_profile_documents["app_staging"]).profile == "application-staging",
      jsondecode(local.executor_permission_profile_documents["app_production"]).profile == "application-production"
    ])
    error_message = "Each repository and reviewed environment must receive its explicit executor permission profile."
  }
  assert {
    condition = alltrue([for environment in ["staging", "production"] :
      one([for statement in jsondecode(local.executor_permission_profile_documents["k8s_${environment}"]).statements : statement if statement.Sid == "RunOnlyReviewedKubernetesPlatformProviderActions"]).Action == [
        "sts:GetCallerIdentity", "apigateway:GET", "apigateway:POST", "apigateway:PATCH", "apigateway:DELETE",
        "elasticloadbalancing:DescribeListeners", "elasticloadbalancing:DescribeRules", "elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTags",
        "elasticloadbalancing:DescribeTargetHealth", "elasticloadbalancing:DescribeListenerAttributes", "elasticloadbalancing:DescribeTargetGroupAttributes", "logs:DescribeLogGroups", "logs:ListTagsForResource",
        "eks:DescribeAccessPolicy", "eks:ListAssociatedAccessPolicies"
      ] &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["k8s_${environment}"]).statements : statement if statement.Sid == "DescribeOnlyItsClusterAccessEntries"]) == {
        Sid      = "DescribeOnlyItsClusterAccessEntries"
        Effect   = "Allow"
        Action   = ["eks:DescribeAccessEntry"]
        Resource = "arn:aws:eks:us-east-1:123456789012:access-entry/oficina-phase3/*"
      }
    ])
    error_message = "Kubernetes platform plans require the reviewed read-only EKS, ELB and CloudWatch Logs discovery actions."
  }
  assert {
    condition = alltrue([
      strcontains(local.executor_permission_profile_documents["db_staging"], "rds:CreateDBInstance"),
      strcontains(local.executor_permission_profile_documents["db_production"], "rds:ModifyDBParameterGroup"),
      !strcontains(local.executor_permission_profile_documents["db_production"], "secretsmanager:PutSecretValue"),
      strcontains(local.executor_permission_profile_documents["functions_staging"], "lambda:CreateFunction"),
      strcontains(local.executor_permission_profile_documents["functions_production"], "dynamodb:UpdateTable"),
      strcontains(local.executor_permission_profile_documents["app_staging"], "eks:DescribeCluster"),
      strcontains(local.executor_permission_profile_documents["app_production"], "ecr:BatchGetImage"),
      strcontains(local.executor_permission_profile_documents["k8s_staging"], "eks:UpdateNodegroupConfig"),
      strcontains(local.executor_permission_profile_documents["k8s_production"], "apigateway:PATCH")
    ])
    error_message = "Each CodeBuild role must contain only the provider capabilities required by its reviewed Terraform owner."
  }
  assert {
    condition = local.codebuild_vpc_project_actions == [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs"
    ]
    error_message = "Every VPC-configured CodeBuild service role must retain exactly the documented VPC network-interface actions."
  }
  assert {
    condition = alltrue([
      !strcontains(local.executor_permission_profile_documents["db_staging"], "lambda:"),
      !strcontains(local.executor_permission_profile_documents["db_production"], "eks:"),
      !strcontains(local.executor_permission_profile_documents["functions_staging"], "rds:"),
      strcontains(local.executor_permission_profile_documents["functions_production"], "apigateway:"),
      strcontains(local.executor_permission_profile_documents["app_staging"], "rds:DescribeDBInstances") && !strcontains(local.executor_permission_profile_documents["app_staging"], "rds:Modify"),
      !strcontains(local.executor_permission_profile_documents["app_production"], "lambda:"),
      !strcontains(local.executor_permission_profile_documents["k8s_staging"], "secretsmanager:"),
      !strcontains(local.executor_permission_profile_documents["k8s_production"], "dynamodb:")
    ])
    error_message = "No executor may inherit another repository's database, function, application, or platform provider permissions."
  }
  assert {
    condition = alltrue([for environment in ["staging", "production"] :
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "ManageOnlyEnvironmentFunctionInvokePermissions"]) == {
        Sid      = "ManageOnlyEnvironmentFunctionInvokePermissions"
        Effect   = "Allow"
        Action   = ["lambda:AddPermission", "lambda:RemovePermission", "lambda:GetPolicy"]
        Resource = "arn:aws:lambda:us-east-1:123456789012:function:oficina-phase3-${environment}-*"
      } &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "ReadOnlyEnvironmentFunctionCodeSigningConfigurations"]) == {
        Sid    = "ReadOnlyEnvironmentFunctionCodeSigningConfigurations"
        Effect = "Allow"
        Action = ["lambda:GetFunctionCodeSigningConfig"]
        Resource = [
          "arn:aws:lambda:us-east-1:123456789012:function:oficina-phase3-${environment}-authorizer",
          "arn:aws:lambda:us-east-1:123456789012:function:oficina-phase3-${environment}-challenge",
          "arn:aws:lambda:us-east-1:123456789012:function:oficina-phase3-${environment}-verification",
          "arn:aws:lambda:us-east-1:123456789012:function:oficina-phase3-${environment}-notification"
        ]
      } &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "ReadAndReleaseSharedFoundationLock"]) == {
        Sid      = "ReadAndReleaseSharedFoundationLock"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::oficina-phase3-state-example/deployment-locks/shared-foundation.json"
      } &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "AcquireSharedFoundationLockConditionally"]) == {
        Sid       = "AcquireSharedFoundationLockConditionally"
        Effect    = "Allow"
        Action    = "s3:PutObject"
        Resource  = "arn:aws:s3:::oficina-phase3-state-example/deployment-locks/shared-foundation.json"
        Condition = { StringEquals = { "s3:if-none-match" = "*" } }
      } &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "ReadOnlyPinnedNewRelicLayerVersions"]).Resource == [
        "arn:aws:lambda:us-east-1:451483290750:layer:NewRelicJava17:29",
        "arn:aws:lambda:us-east-1:451483290750:layer:NewRelicLambdaExtension:77"
      ] &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "DiscoverOnlyReviewedEnvironmentGatewayCollections"]).Action == ["apigateway:GET"] &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "DiscoverOnlyReviewedEnvironmentGatewayCollections"]).Resource == [
        "arn:aws:apigateway:us-east-1::/apis/${environment == "staging" ? "stage123" : "prod456"}",
        "arn:aws:apigateway:us-east-1::/apis/${environment == "staging" ? "stage123" : "prod456"}/authorizers",
        "arn:aws:apigateway:us-east-1::/apis/${environment == "staging" ? "stage123" : "prod456"}/integrations",
        "arn:aws:apigateway:us-east-1::/apis/${environment == "staging" ? "stage123" : "prod456"}/routes"
      ] &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "CreateOnlyReviewedEnvironmentGatewayBindings"]).Action == ["apigateway:POST"] &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "ManageOnlyReviewedEnvironmentGatewayResources"]).Action == ["apigateway:GET", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE"] &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "ManageOnlyReviewedEnvironmentGatewayResources"]).Resource == [
        "arn:aws:apigateway:us-east-1::/apis/${environment == "staging" ? "stage123" : "prod456"}/authorizers/${environment == "staging" ? "authstage" : "authprod"}",
        "arn:aws:apigateway:us-east-1::/apis/${environment == "staging" ? "stage123" : "prod456"}/integrations/${environment == "staging" ? "intstage1" : "intprod1"}",
        "arn:aws:apigateway:us-east-1::/apis/${environment == "staging" ? "stage123" : "prod456"}/integrations/${environment == "staging" ? "intstage2" : "intprod2"}",
        "arn:aws:apigateway:us-east-1::/apis/${environment == "staging" ? "stage123" : "prod456"}/routes/${environment == "staging" ? "routestage1" : "routeprod1"}",
        "arn:aws:apigateway:us-east-1::/apis/${environment == "staging" ? "stage123" : "prod456"}/routes/${environment == "staging" ? "routestage2" : "routeprod2"}"
      ] &&
      !strcontains(local.executor_permission_profile_documents["functions_${environment}"], "/apis/*") &&
      !strcontains(local.executor_permission_profile_documents["functions_${environment}"], "/routes/*") &&
      !strcontains(local.executor_permission_profile_documents["functions_${environment}"], "/integrations/*") &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "ManageOnlyEnvironmentFunctionEventMappings"]) == {
        Sid      = "ManageOnlyEnvironmentFunctionEventMappings"
        Effect   = "Allow"
        Action   = ["lambda:CreateEventSourceMapping", "lambda:UpdateEventSourceMapping", "lambda:DeleteEventSourceMapping", "lambda:ListEventSourceMappings"]
        Resource = "*"
        Condition = { ArnEquals = {
          "lambda:FunctionArn" = "arn:aws:lambda:us-east-1:123456789012:function:oficina-phase3-${environment}-notification"
        } }
      }
    ])
    error_message = "Functions executors must manage only the reviewed Lambda invoke, pinned New Relic layer and API Gateway v2 binding resources."
  }
  assert {
    condition = alltrue([for environment in ["staging", "production"] :
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "CreateOnlyTaggedEnvironmentAlarmTopic"]).Condition.StringEquals["aws:RequestTag/environment"] == environment &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "TagOnlyEnvironmentAlarmTopicOnCreate"]).Action == ["sns:TagResource"] &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "ManageOnlyEnvironmentAlarmTopic"]).Condition.StringEquals["aws:ResourceTag/environment"] == environment &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "ManageOnlyEnvironmentAlarmTopic"]).Resource == "arn:aws:sns:us-east-1:123456789012:oficina-phase3-${environment}-native-alarms" &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "ManageOnlyEnvironmentAlarmSubscriptions"]).Resource == [
        "arn:aws:sns:us-east-1:123456789012:oficina-phase3-${environment}-native-alarms",
        "arn:aws:sns:us-east-1:123456789012:oficina-phase3-${environment}-native-alarms:*"
      ] &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "ManageOnlyEnvironmentNativeAlarms"]).Resource == "arn:aws:cloudwatch:us-east-1:123456789012:alarm:oficina-phase3-${environment}-*" &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "DescribeOnlyEnvironmentNativeAlarms"]).Resource == "*"
    ])
    error_message = "Native alarms must use environment-scoped SNS topics/subscriptions and CloudWatch alarm names."
  }
  assert {
    condition = (alltrue([for environment in ["staging", "production"] :
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "ManageOnlyNamedEnvironmentTables"]).Action == ["dynamodb:DescribeTable", "dynamodb:UpdateTable", "dynamodb:DeleteTable", "dynamodb:DescribeContinuousBackups", "dynamodb:UpdateContinuousBackups", "dynamodb:DescribeTimeToLive", "dynamodb:UpdateTimeToLive", "dynamodb:ListTagsOfResource", "dynamodb:TagResource", "dynamodb:UntagResource"] &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "DescribeOnlyEnvironmentRuntimeSecretReferences"]).Action == ["secretsmanager:DescribeSecret"] &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "DescribeOnlyEnvironmentRuntimeSecretReferences"]).Resource == [
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/${environment}/auth-lookup-*",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/${environment}/notification-lookup-*",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/${environment}/customer-signing-*",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/${environment}/authorizer-trust-*",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/${environment}/rds-ca-*",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/${environment}/newrelic-ingest-*"
      ] &&
      !strcontains(local.executor_permission_profile_documents["functions_${environment}"], "secretsmanager:GetSecretValue") &&
      !strcontains(local.executor_permission_profile_documents["functions_${environment}"], environment == "staging" ? "production" : "staging") &&
      !strcontains(jsonencode(one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "ReadOnlyPinnedNewRelicLayerVersions"])), ":*") &&
      !strcontains(jsonencode(one([for statement in jsondecode(local.executor_permission_profile_documents["functions_${environment}"]).statements : statement if statement.Sid == "ReadOnlyEnvironmentFunctionCodeSigningConfigurations"])), "function:${var.name}-${environment}-*") &&
      !strcontains(local.executor_permission_profile_documents["functions_${environment}"], "deployment-locks/*")
      ]) &&
      alltrue([for key in ["k8s_staging", "k8s_production", "db_staging", "db_production", "app_staging", "app_production"] :
        !strcontains(local.executor_permission_profile_documents[key], "lambda:AddPermission") &&
        !strcontains(local.executor_permission_profile_documents[key], "sns:CreateTopic") &&
        !strcontains(local.executor_permission_profile_documents[key], "dynamodb:UpdateTimeToLive")
    ]))
    error_message = "Functions executor metadata reads must include DynamoDB TTL/PITR/tag actions and never grant runtime secret values or cross-environment or cross-owner permissions."
  }
  assert {
    condition = (!strcontains(local.executor_permission_profile_documents["functions_staging"], "/apis/prod456/") && !strcontains(local.executor_permission_profile_documents["functions_production"], "/apis/stage123/") &&
      !strcontains(local.executor_permission_profile_documents["functions_staging"], "/apis/stage123/integrations/intprod") &&
      !strcontains(local.executor_permission_profile_documents["functions_production"], "/apis/prod456/routes/routestage") &&
      one([for statement in jsondecode(local.executor_permission_profile_documents["functions_staging"]).statements : statement if statement.Sid == "CreateOnlyTaggedEnvironmentAlarmTopic"]).Condition.StringEquals["aws:RequestTag/project"] == "oficina-phase3" &&
    one([for statement in jsondecode(local.executor_permission_profile_documents["functions_staging"]).statements : statement if statement.Sid == "ManageOnlyEnvironmentAlarmTopic"]).Condition.StringEquals["aws:ResourceTag/project"] == "oficina-phase3")
    error_message = "FUN gateway permissions must exclude the opposite environment API, and SNS writes/management must use the correct request/resource tag conditions."
  }
  assert {
    condition     = aws_ecr_repository.deployer.image_tag_mutability == "IMMUTABLE" && can(regex("^sha256:", var.deployer_image_digest))
    error_message = "Every deployer must consume the platform ECR image by immutable digest."
  }
  assert {
    condition = alltrue([for key, project in aws_codebuild_project.deploy :
      project.source[0].buildspec == local.rendered_deployment_buildspecs[key] &&
      !contains([for variable in project.environment[0].environment_variable : variable.name], "DEPLOYMENT_TFVARS_PATH") &&
      !contains([for variable in project.environment[0].environment_variable : variable.name], "DEPLOYMENT_MODE") &&
      !contains([for variable in project.environment[0].environment_variable : variable.name], "TERRAFORM_BACKEND_BUCKET") &&
      !contains([for variable in project.environment[0].environment_variable : variable.name], "TERRAFORM_BACKEND_KEY") &&
      !contains([for variable in project.environment[0].environment_variable : variable.name], "TERRAFORM_BACKEND_LOCK_KEY") &&
      !contains([for variable in project.environment[0].environment_variable : variable.name], "TERRAFORM_BACKEND_REGION") &&
      strcontains(project.source[0].buildspec, "reviewed_environment=\"${var.deployments[key].environment}\"") &&
      strcontains(project.source[0].buildspec, "reviewed_backend_bucket=\"${var.state_bucket_name}\"") &&
      strcontains(project.source[0].buildspec, "reviewed_backend_key=\"${var.deployments[key].terraform_state_key}\"") &&
      strcontains(project.source[0].buildspec, "reviewed_backend_lock_key=\"${var.deployments[key].terraform_state_key}.tflock\"") &&
      strcontains(project.source[0].buildspec, "reviewed_backend_region=\"${var.aws_region}\"") &&
      strcontains(project.source[0].buildspec, "reviewed_deployment_mode=\"${var.deployments[key].deployment_mode}\"") &&
      strcontains(project.source[0].buildspec, "reviewed_tfvars_path=\"${var.deployments[key].terraform_variables_path}\"") &&
      strcontains(project.source[0].buildspec, "Deployment environment override does not match this reviewed executor.") &&
      !strcontains(project.source[0].buildspec, "$${TERRAFORM_BACKEND_KEY}")
    ])
    error_message = "Every executor must render its exact backend, deployment mode, and tfvars path into the Terraform-owned bootstrap, outside StartBuild overrides."
  }
  assert {
    condition = alltrue([
      for repository in distinct([for deployment in values(var.deployments) : deployment.repository]) :
      length([for deployment in values(var.deployments) : deployment.environment if deployment.repository == repository]) == 2 &&
      toset([for deployment in values(var.deployments) : deployment.environment if deployment.repository == repository]) == toset(["staging", "production"])
    ])
    error_message = "Every repository must receive exactly one executor for each reviewed environment."
  }
}

run "database_permissions_reject_broad_and_cross_environment_scope" {
  command = plan
  override_resource {
    target          = aws_ecr_repository.deployer
    override_during = plan
    values          = { arn = "arn:aws:ecr:us-east-1:123456789012:repository/oficina-phase3-deployer" }
  }
  assert {
    condition = alltrue([for environment in ["staging", "production"] :
      length(local.codebuild_policies["db_${environment}"]) <= 10240 &&
      length(jsondecode(local.executor_permission_profile_documents["db_${environment}"]).statements) == 17 &&
      !strcontains(local.codebuild_policies["db_${environment}"], environment == "staging" ? "production" : "staging") &&
      alltrue([for statement in jsondecode(local.executor_permission_profile_documents["db_${environment}"]).statements :
        statement.Effect == "Allow" &&
        toset(try(tolist(statement.Resource), [tostring(statement.Resource)])) == toset({
          DescribeDatabaseCatalogAndNetwork        = ["*"]
          CreateNamedDatabaseResources             = [for type in ["db", "subgrp", "pg"] : "arn:aws:rds:us-east-1:123456789012:${type}:oficina-phase3-${environment}-postgres"]
          ManageNamedDatabaseResources             = [for type in ["db", "subgrp", "pg"] : "arn:aws:rds:us-east-1:123456789012:${type}:oficina-phase3-${environment}-postgres"]
          UseDefaultPostgresOptionGroup            = ["arn:aws:rds:us-east-1:123456789012:og:default:postgres-16"]
          CreateOnlyDatabaseFinalSnapshot          = ["arn:aws:rds:us-east-1:123456789012:db:oficina-phase3-${environment}-postgres", "arn:aws:rds:us-east-1:123456789012:snapshot:oficina-phase3-${environment}-postgres-final"]
          CreateDatabaseGroupInReviewedVpc         = ["arn:aws:ec2:us-east-1:123456789012:vpc/vpc-12345678"]
          CreateTaggedDatabaseGroup                = ["arn:aws:ec2:us-east-1:123456789012:security-group/*"]
          ManageDatabaseGroupsInReviewedVpc        = ["arn:aws:ec2:us-east-1:123456789012:security-group/*"]
          CreateTaggedDatabaseIngressRules         = ["arn:aws:ec2:us-east-1:123456789012:security-group-rule/*"]
          ModifyTaggedDatabaseRules                = ["arn:aws:ec2:us-east-1:123456789012:security-group-rule/*"]
          TagDatabaseNetworkResourcesOnCreate      = ["arn:aws:ec2:us-east-1:123456789012:security-group/*", "arn:aws:ec2:us-east-1:123456789012:security-group-rule/*"]
          RetagOnlyOwnedDatabaseNetworkResources   = ["arn:aws:ec2:us-east-1:123456789012:security-group/*", "arn:aws:ec2:us-east-1:123456789012:security-group-rule/*"]
          CreateAndTagOnlyRdsManagedMasterSecret   = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-*"]
          DescribeOnlyAwsManagedDatabaseKeys       = ["arn:aws:kms:us-east-1:123456789012:key/*"]
          PublishOnlyDatabaseEnvironmentOutputs    = ["arn:aws:s3:::oficina-phase3-artifacts-example/releases/database/${environment}/outputs/*.json"]
          ReadAndReleaseSharedFoundationLock       = ["arn:aws:s3:::oficina-phase3-state-example/deployment-locks/shared-foundation.json"]
          AcquireSharedFoundationLockConditionally = ["arn:aws:s3:::oficina-phase3-state-example/deployment-locks/shared-foundation.json"]
        }[statement.Sid])
      ])
    ])
    error_message = "DB policy must fit the role inline quota and every grant must use the reviewed account, region, exact name/prefix or justified generated-ID scope, with no opposite environment."
  }
  assert {
    condition = alltrue(flatten([for environment in ["staging", "production"] : [
      for statement in jsondecode(local.executor_permission_profile_documents["db_${environment}"]).statements :
      alltrue([for tag in ["project", "environment", "owner"] :
        statement.Condition.StringEquals["aws:RequestTag/${tag}"] == { project = "oficina-phase3", environment = environment, owner = "oficina-db-infra" }[tag]
      ]) if contains(["CreateNamedDatabaseResources", "CreateTaggedDatabaseGroup", "CreateTaggedDatabaseIngressRules", "TagDatabaseNetworkResourcesOnCreate"], statement.Sid)
      ]])) && alltrue(flatten([for environment in ["staging", "production"] : [
      for statement in jsondecode(local.executor_permission_profile_documents["db_${environment}"]).statements :
      alltrue([for tag in ["project", "environment", "owner"] :
        statement.Condition.StringEquals["aws:ResourceTag/${tag}"] == { project = "oficina-phase3", environment = environment, owner = "oficina-db-infra" }[tag]
      ]) if contains(["ManageDatabaseGroupsInReviewedVpc", "ModifyTaggedDatabaseRules", "RetagOnlyOwnedDatabaseNetworkResources"], statement.Sid)
    ]]))
    error_message = "DB network creation and management must require project, owner and exact environment tags."
  }
  assert {
    condition = alltrue([for environment in ["staging", "production"] :
      alltrue([for statement in jsondecode(local.executor_permission_profile_documents["db_${environment}"]).statements :
        statement.Condition.ArnEquals["ec2:Vpc"] == "arn:aws:ec2:us-east-1:123456789012:vpc/vpc-12345678" if statement.Sid == "ManageDatabaseGroupsInReviewedVpc"
      ]) &&
      alltrue([for statement in jsondecode(local.executor_permission_profile_documents["db_${environment}"]).statements :
        toset(statement.Condition["ForAllValues:StringNotEquals"]["aws:TagKeys"]) == toset(["project", "environment", "owner"]) if statement.Sid == "RetagOnlyOwnedDatabaseNetworkResources"
      ]) &&
      alltrue([for statement in jsondecode(local.executor_permission_profile_documents["db_${environment}"]).statements :
        toset(statement.Condition.StringEquals["ec2:CreateAction"]) == toset(["CreateSecurityGroup", "AuthorizeSecurityGroupIngress"]) if statement.Sid == "TagDatabaseNetworkResourcesOnCreate"
      ]) &&
      alltrue([for statement in jsondecode(local.executor_permission_profile_documents["db_${environment}"]).statements :
        toset(statement.Action) == toset(["secretsmanager:CreateSecret", "secretsmanager:TagResource"]) &&
        statement.Condition["ForAnyValue:StringEquals"]["aws:CalledVia"] == ["rds.amazonaws.com"] &&
        statement.Condition.StringEqualsIfExists["aws:RequestTag/aws:rds:primaryDBInstanceArn"] == "arn:aws:rds:us-east-1:123456789012:db:oficina-phase3-${environment}-postgres" &&
        statement.Condition.StringEqualsIfExists["aws:ResourceTag/aws:rds:primaryDBInstanceArn"] == "arn:aws:rds:us-east-1:123456789012:db:oficina-phase3-${environment}-postgres"
        if statement.Sid == "CreateAndTagOnlyRdsManagedMasterSecret"
      ]) &&
      alltrue([for statement in jsondecode(local.executor_permission_profile_documents["db_${environment}"]).statements :
        statement.Action == "kms:DescribeKey" && toset(statement.Condition["ForAnyValue:StringEquals"]["kms:ResourceAliases"]) == toset(["alias/aws/rds", "alias/aws/secretsmanager"])
        if statement.Sid == "DescribeOnlyAwsManagedDatabaseKeys"
      ]) &&
      !can(regex("GetSecretValue|PutSecretValue|DeleteSecret|kms:Decrypt|iam:|rds:\\*|ec2:\\*|secretsmanager:\\*|s3:\\*", local.executor_permission_profile_documents["db_${environment}"]))
    ])
    error_message = "DB grants must preserve VPC isolation, immutable ownership tags, RDS-only managed-secret integration and alias-limited key metadata without runtime secrets or administrative actions."
  }
  assert {
    condition = alltrue([for environment in ["staging", "production"] :
      alltrue([for statement in jsondecode(local.codebuild_policies["db_${environment}"]).Statement :
        statement.Resource == "arn:aws:s3:::oficina-phase3-state-example/database/${environment}.tfstate" &&
        toset(statement.Action) == toset(["s3:GetObject", "s3:PutObject"]) if statement.Sid == "ReadWriteOnlyItsTerraformState"
      ]) &&
      alltrue([for statement in jsondecode(local.codebuild_policies["db_${environment}"]).Statement :
        statement.Resource == "arn:aws:s3:::oficina-phase3-state-example/database/${environment}.tfstate.tflock" &&
        toset(statement.Action) == toset(["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]) if statement.Sid == "LockOnlyItsTerraformLockfile"
      ]) &&
      alltrue([for statement in jsondecode(local.executor_permission_profile_documents["db_${environment}"]).statements :
        statement.Action == "s3:PutObject" && statement.Condition.StringEquals["s3:if-none-match"] == "*" if statement.Sid == "AcquireSharedFoundationLockConditionally"
      ]) &&
      alltrue([for statement in jsondecode(local.executor_permission_profile_documents["db_${environment}"]).statements :
        statement.Condition.StringEquals["aws:RequestedRegion"] == "us-east-1" &&
        toset(statement.Action) == toset(["ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules", "rds:DescribeDBEngineVersions", "rds:DescribeOrderableDBInstanceOptions", "rds:DescribeDBInstances"])
        if statement.Resource == "*"
      ]) &&
      alltrue([for statement in jsondecode(local.executor_permission_profile_documents["db_${environment}"]).statements :
        !contains(statement.Action, "rds:DescribeDBInstances") if statement.Sid == "ManageNamedDatabaseResources"
      ])
    ])
    error_message = "DB state deletion, broad catalog actions and unconditional shared-lock overwrite must remain unauthorized."
  }
}

run "rejects_cross_environment_bootstrap_reference" {
  command = plan
  variables {
    application_bootstrap_secret_refs = {
      staging = {
        database_arn = "arn:aws:rds:us-east-1:123456789012:db:oficina-phase3-production-postgres"
        master       = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-0123456789abcdef", version_id = "12345678901234567890123456789012", database_arn = "arn:aws:rds:us-east-1:123456789012:db:oficina-phase3-production-postgres" }
        migration    = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/migration-AbCdEf", version_id = "23456789012345678901234567890123" }
        app          = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/app-AbCdEf", version_id = "34567890123456789012345678901234" }
        auth         = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/auth-AbCdEf", version_id = "45678901234567890123456789012345" }
        notification = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oficina/staging/notification-AbCdEf", version_id = "56789012345678901234567890123456" }
      }
    }
  }
  expect_failures = [var.application_bootstrap_secret_refs]
}

run "rejects_unreviewed_gateway_and_newrelic_inputs" {
  command = plan
  variables {
    function_gateway_bindings = {
      staging = {
        api_id                      = "prod-api"
        authorizer_id               = "authstage"
        challenge_integration_id    = "intstage1"
        verification_integration_id = "intstage2"
        challenge_route_id          = "routestage1"
        verification_route_id       = "routestage2"
      }
    }
    newrelic_layer_version_arns = {
      java_slim = "arn:aws:lambda:us-east-1:451483290750:layer:NewRelicJava17:*"
      extension = "arn:aws:lambda:us-east-1:451483290750:layer:NewRelicLambdaExtension:77"
    }
  }
  expect_failures = [var.function_gateway_bindings, var.newrelic_layer_version_arns]
}

run "rejects_duplicate_environment_gateway_api_ids" {
  command = plan
  variables {
    function_gateway_bindings = {
      staging = {
        api_id = "same123", authorizer_id = "authstage", challenge_integration_id = "intstage1", verification_integration_id = "intstage2", challenge_route_id = "routestage1", verification_route_id = "routestage2"
      }
      production = {
        api_id = "same123", authorizer_id = "authprod", challenge_integration_id = "intprod1", verification_integration_id = "intprod2", challenge_route_id = "routeprod1", verification_route_id = "routeprod2"
      }
    }
  }
  expect_failures = [var.function_gateway_bindings]
}

run "fails_closed_without_pinned_newrelic_layers" {
  command = plan
  variables {
    newrelic_layer_version_arns = null
  }
  assert {
    condition = alltrue([for environment in ["staging", "production"] :
      !strcontains(local.executor_permission_profile_documents["functions_${environment}"], "ReadOnlyPinnedNewRelicLayerVersions")
    ])
    error_message = "Missing New Relic layer versions must withhold layer-read access until reviewed pins are supplied."
  }
}

run "rejects_duplicate_environment_for_a_repository" {
  command = plan

  variables {
    deployments = {
      k8s_staging           = { repository = "oficina-k8s-infra", environment = "staging", source_prefix = "releases/k8s/staging", terraform_state_key = "environments/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/k8s_staging.tfvars.json" }
      k8s_production        = { repository = "oficina-k8s-infra", environment = "production", source_prefix = "releases/k8s/production", terraform_state_key = "environments/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/k8s_production.tfvars.json" }
      db_staging            = { repository = "oficina-db-infra", environment = "staging", source_prefix = "releases/database/staging", terraform_state_key = "database/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/database_staging.tfvars.json" }
      db_production         = { repository = "oficina-db-infra", environment = "production", source_prefix = "releases/database/production", terraform_state_key = "database/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/database_production.tfvars.json" }
      functions_staging     = { repository = "oficina-functions", environment = "staging", source_prefix = "releases/functions/staging", terraform_state_key = "functions/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/functions_staging.tfvars.json" }
      functions_production  = { repository = "oficina-functions", environment = "production", source_prefix = "releases/functions/production", terraform_state_key = "functions/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/functions_production.tfvars.json" }
      app_staging           = { repository = "oficina-app", environment = "staging", source_prefix = "releases/app/staging", terraform_state_key = "app/staging.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/app_staging.tfvars.json" }
      app_staging_duplicate = { repository = "oficina-app", environment = "staging", source_prefix = "releases/app/staging-duplicate", terraform_state_key = "app/production.tfstate", deployment_mode = "plan", terraform_variables_path = "/tmp/oficina/app_production.tfvars.json" }
    }
  }

  expect_failures = [var.deployments]
}
