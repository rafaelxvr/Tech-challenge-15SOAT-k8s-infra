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
      !strcontains(local.executor_permission_profile_documents["functions_production"], "apigateway:"),
      !strcontains(local.executor_permission_profile_documents["app_staging"], "rds:"),
      !strcontains(local.executor_permission_profile_documents["app_production"], "lambda:"),
      !strcontains(local.executor_permission_profile_documents["k8s_staging"], "secretsmanager:"),
      !strcontains(local.executor_permission_profile_documents["k8s_production"], "dynamodb:")
    ])
    error_message = "No executor may inherit another repository's database, function, application, or platform provider permissions."
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
        toset(statement.Action) == toset(["ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules", "rds:DescribeDBEngineVersions", "rds:DescribeOrderableDBInstanceOptions"])
        if statement.Resource == "*"
      ])
    ])
    error_message = "DB state deletion, broad catalog actions and unconditional shared-lock overwrite must remain unauthorized."
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
