mock_provider "aws" {}

variables {
  account_id               = "123456789012"
  state_bucket_name        = "oficina-phase3-state-example"
  artifact_bucket_name     = "oficina-phase3-artifacts-example"
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  state_keys = {
    bootstrap = "bootstrap/terraform.tfstate"
    staging   = "environments/staging/terraform.tfstate"
  }
  launchers = {
    k8s_staging = {
      repository            = "example/oficina-k8s-infra"
      environment           = "staging"
      branch                = "develop"
      source_prefix         = "releases/k8s/staging"
      codebuild_project_arn = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-staging"
    }
    k8s_production = {
      repository            = "example/oficina-k8s-infra"
      environment           = "production"
      branch                = "main"
      source_prefix         = "releases/k8s/production"
      codebuild_project_arn = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-production"
    }
  }
}

run "state_is_protected" {
  command = apply

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State versions must survive an accidental overwrite."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.state.block_public_acls && aws_s3_bucket_public_access_block.state.block_public_policy && aws_s3_bucket_public_access_block.state.ignore_public_acls && aws_s3_bucket_public_access_block.state.restrict_public_buckets
    error_message = "State must block every public access path."
  }

  assert {
    condition     = aws_s3_bucket.state.force_destroy == false && aws_s3_bucket.artifact.force_destroy == false
    error_message = "Buckets must retain data unless an operator explicitly destroys it outside this module."
  }

  assert {
    condition     = can(regex("aws:SecureTransport", aws_s3_bucket_policy.state_https_only.policy))
    error_message = "State bucket policy must deny non-HTTPS requests."
  }
}

run "trust_subjects_are_environment_scoped" {
  command = plan

  assert {
    condition     = output.launcher_trust_subjects["k8s_staging"] == "repo:example/oficina-k8s-infra:environment:staging"
    error_message = "Staging trust must be an exact environment subject, not a wildcard or pull-request subject."
  }

  assert {
    condition     = can(regex("sts.amazonaws.com", output.launcher_trust_policies["k8s_production"]))
    error_message = "GitHub OIDC trust must require sts.amazonaws.com audience."
  }

  assert {
    condition = (
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyBuildspecOverride"]).Effect == "Deny" &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyBuildspecOverride"]).Action == "codebuild:StartBuild" &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyBuildspecOverride"]).Resource == var.launchers["k8s_staging"].codebuild_project_arn &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyBuildspecOverride"]).Condition.Null["codebuild:source.buildspec"] == "false"
    )
    error_message = "The parsed launcher IAM policy must deny only StartBuild requests that supply buildspecOverride, on its exact project."
  }

  assert {
    condition = (
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "StartOnlyItsDeploymentProject"]).Effect == "Allow" &&
      contains(one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "StartOnlyItsDeploymentProject"]).Action, "codebuild:StartBuild") &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "StartOnlyItsDeploymentProject"]).Resource == var.launchers["k8s_staging"].codebuild_project_arn &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyBuildspecOverride"]).Condition.Null["codebuild:source.buildspec"] == "false"
    )
    error_message = "An ordinary StartBuild without buildspecOverride remains allowed for the exact reviewed project."
  }

  assert {
    condition = (
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyDeploymentControlOverrides"]).Effect == "Deny" &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyDeploymentControlOverrides"]).Action == "codebuild:StartBuild" &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyDeploymentControlOverrides"]).Resource == var.launchers["k8s_staging"].codebuild_project_arn &&
      toset(one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyDeploymentControlOverrides"]).Condition["ForAnyValue:StringEquals"]["codebuild:environment.environmentVariables.name"]) == toset(["DEPLOYMENT_MODE", "DEPLOYMENT_TFVARS_PATH"])
    )
    error_message = "The parsed launcher IAM policy must deny only mode and tfvars StartBuild environment overrides on its exact project."
  }
}

run "rejects_wrong_branch_for_environment" {
  command = plan

  variables {
    launchers = {
      invalid = {
        repository            = "example/oficina-k8s-infra"
        environment           = "production"
        branch                = "develop"
        source_prefix         = "releases/k8s/production"
        codebuild_project_arn = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-production"
      }
    }
  }

  expect_failures = [var.launchers]
}

run "rejects_oidc_provider_from_another_account" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::210987654321:oidc-provider/token.actions.githubusercontent.com"
  }

  expect_failures = [var.github_oidc_provider_arn]
}

run "rejects_codebuild_project_outside_approved_account_or_region" {
  command = plan

  variables {
    launchers = {
      invalid = {
        repository            = "example/oficina-k8s-infra"
        environment           = "staging"
        branch                = "develop"
        source_prefix         = "releases/k8s/staging"
        codebuild_project_arn = "arn:aws:codebuild:us-west-2:210987654321:project/oficina-k8s-staging"
      }
    }
  }

  expect_failures = [var.launchers]
}

run "rejects_runtime_role_from_another_account" {
  command = plan

  variables {
    runtime_role_arns = ["arn:aws:iam::210987654321:role/oficina-runtime"]
  }

  expect_failures = [var.runtime_role_arns]
}
